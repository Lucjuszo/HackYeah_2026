from typing import Any

from bson import ObjectId
from pymongo import ReturnDocument
from pymongo.asynchronous.database import AsyncDatabase
from pymongo.errors import DuplicateKeyError

from app.db import parse_object_id, utcnow
from app.models.place import Coordinates, MenuItem, Photo, Place, PlaceCreate, PlaceUpdate
from app.storage import get_storage

COLLECTION = "places"

# Fields stored exactly as the model dumps them (mode="json" turns enums into plain str/int for BSON).
_PLAIN_FIELDS = {"name", "amenities", "opening_hours", "usage_price", "atmosphere", "features"}


class PlaceAlreadyExists(Exception):
    pass


def _geo_point(coordinates: Coordinates) -> dict[str, Any]:
    # GeoJSON point – order is [lon, lat]; enables 2dsphere queries ($near, $geoWithin).
    return {"type": "Point", "coordinates": [coordinates.lon, coordinates.lat]}


def _menu(menu: list[MenuItem]) -> list[dict[str, Any]]:
    return [item.model_dump(exclude_none=True) for item in menu]


def to_document(place: PlaceCreate, user_id: str) -> dict[str, Any]:
    now = utcnow()
    doc: dict[str, Any] = {
        **place.model_dump(mode="json", include=_PLAIN_FIELDS),
        "address": place.address.model_dump(exclude_none=True),
        "location": _geo_point(place.coordinates),
        "menu": _menu(place.menu),
        "photos": [],
        "rating": {"average": None, "count": 0},
        "created_by": user_id,
        "updated_by": user_id,
        "created_at": now,
        "updated_at": now,
    }
    # Omit instead of storing null, so the partial unique index skips places without an OSM link.
    if place.osm:
        doc["osm"] = place.osm.model_dump(mode="json")
    return doc


def to_update_operations(update: PlaceUpdate, user_id: str) -> dict[str, Any]:
    fields = update.model_fields_set
    to_set: dict[str, Any] = {"updated_at": utcnow(), "updated_by": user_id}
    to_unset: dict[str, Any] = {}

    for field, value in update.model_dump(mode="json", include=fields & (_PLAIN_FIELDS - {"amenities"})).items():
        to_set[field] = value
    if "amenities" in fields:
        # Merge flag by flag instead of replacing the whole object.
        for flag, value in update.amenities.model_dump(exclude_unset=True).items():
            to_set[f"amenities.{flag}"] = value
    if "address" in fields:
        to_set["address"] = update.address.model_dump(exclude_none=True)
    if "coordinates" in fields:
        to_set["location"] = _geo_point(update.coordinates)
    if "menu" in fields:
        to_set["menu"] = _menu(update.menu)
    if "osm" in fields:
        if update.osm:
            to_set["osm"] = update.osm.model_dump(mode="json")
        else:
            to_unset["osm"] = ""  # unset, not null – same reason as in to_document

    operations: dict[str, Any] = {"$set": to_set}
    if to_unset:
        operations["$unset"] = to_unset
    return operations


def from_document(doc: dict[str, Any]) -> Place:
    lon, lat = doc["location"]["coordinates"]
    return Place(
        id=str(doc["_id"]),
        name=doc["name"],
        address=doc["address"],
        coordinates=Coordinates(lat=lat, lon=lon),
        amenities=doc.get("amenities", {}),
        opening_hours=doc.get("opening_hours"),
        usage_price=doc.get("usage_price"),
        atmosphere=doc.get("atmosphere"),
        features=doc.get("features", []),
        menu=doc.get("menu", []),
        osm=doc.get("osm"),
        photos=[photo_from_subdocument(p) for p in doc.get("photos", [])],
        rating=doc.get("rating", {}),
        created_by=doc.get("created_by"),
        updated_by=doc.get("updated_by"),
        created_at=doc["created_at"],
        updated_at=doc["updated_at"],
    )


def photo_from_subdocument(sub: dict[str, Any]) -> Photo:
    # Only the storage key is persisted; the URL depends on the storage backend / CDN in use.
    return Photo(
        id=sub["id"],
        url=get_storage().url(sub["key"]),
        content_type=sub["content_type"],
        width=sub["width"],
        height=sub["height"],
        size=sub["size"],
        created_at=sub["created_at"],
    )


async def ensure_indexes(db: AsyncDatabase) -> None:
    places = db[COLLECTION]
    await places.create_index([("location", "2dsphere")])
    await places.create_index(
        [("osm.type", 1), ("osm.id", 1)],
        unique=True,
        partialFilterExpression={"osm.id": {"$exists": True}},
    )


async def place_exists(db: AsyncDatabase, place_id: ObjectId) -> bool:
    return await db[COLLECTION].count_documents({"_id": place_id}, limit=1) > 0


async def create_place(db: AsyncDatabase, place: PlaceCreate, user_id: str) -> Place:
    doc = to_document(place, user_id)
    try:
        result = await db[COLLECTION].insert_one(doc)
    except DuplicateKeyError as e:
        raise PlaceAlreadyExists from e
    doc["_id"] = result.inserted_id
    return from_document(doc)


async def update_place(db: AsyncDatabase, place_id: str, update: PlaceUpdate, user_id: str) -> Place | None:
    """Returns None if the place doesn't exist; raises PlaceAlreadyExists on an OSM link conflict."""
    oid = parse_object_id(place_id)
    if oid is None:
        return None
    try:
        doc = await db[COLLECTION].find_one_and_update(
            {"_id": oid}, to_update_operations(update, user_id), return_document=ReturnDocument.AFTER
        )
    except DuplicateKeyError as e:
        raise PlaceAlreadyExists from e
    return from_document(doc) if doc else None


async def get_place(db: AsyncDatabase, place_id: str) -> Place | None:
    oid = parse_object_id(place_id)
    if oid is None:
        return None
    doc = await db[COLLECTION].find_one({"_id": oid})
    return from_document(doc) if doc else None


async def list_places(
    db: AsyncDatabase,
    *,
    near: Coordinates | None = None,
    radius_m: int = 1000,
    power_outlets: bool | None = None,
    limit: int = 50,
    skip: int = 0,
) -> list[Place]:
    query: dict[str, Any] = {}
    if near:
        # $near sorts results by distance, closest first.
        query["location"] = {"$near": {"$geometry": _geo_point(near), "$maxDistance": radius_m}}
    if power_outlets is not None:
        query["amenities.power_outlets"] = power_outlets
    cursor = db[COLLECTION].find(query).skip(skip).limit(limit)
    return [from_document(doc) async for doc in cursor]


class PhotoLimitReached(Exception):
    pass


async def add_photo(db: AsyncDatabase, place_id: str, photo: dict[str, Any], max_photos: int) -> Photo | None:
    """Returns None if the place doesn't exist. Limit check and push happen atomically in one update."""
    oid = parse_object_id(place_id)
    if oid is None:
        return None
    result = await db[COLLECTION].update_one(
        {"_id": oid, f"photos.{max_photos - 1}": {"$exists": False}},
        {"$push": {"photos": photo}, "$set": {"updated_at": utcnow()}},
    )
    if result.matched_count == 0:
        if await place_exists(db, oid):
            raise PhotoLimitReached
        return None
    return photo_from_subdocument(photo)


async def remove_photo(db: AsyncDatabase, place_id: str, photo_id: str) -> str | None:
    """Removes the photo entry and returns its storage key, or None if not found."""
    oid = parse_object_id(place_id)
    if oid is None:
        return None
    doc = await db[COLLECTION].find_one_and_update(
        {"_id": oid, "photos.id": photo_id},
        {"$pull": {"photos": {"id": photo_id}}, "$set": {"updated_at": utcnow()}},
        projection={"photos": {"$elemMatch": {"id": photo_id}}},
    )
    return doc["photos"][0]["key"] if doc else None
