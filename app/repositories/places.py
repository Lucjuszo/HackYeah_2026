from datetime import UTC, datetime
from typing import Any

from bson import ObjectId
from bson.errors import InvalidId
from pymongo.asynchronous.database import AsyncDatabase
from pymongo.errors import DuplicateKeyError

from app.models.place import Coordinates, Photo, Place, PlaceCreate
from app.storage import get_storage

COLLECTION = "places"


class PlaceAlreadyExists(Exception):
    pass


def to_document(place: PlaceCreate) -> dict[str, Any]:
    now = datetime.now(UTC)
    doc: dict[str, Any] = {
        # mode="json" turns enums into plain str/int, which is what BSON stores.
        **place.model_dump(
            mode="json",
            include={"name", "amenities", "opening_hours", "usage_price", "atmosphere", "features"},
        ),
        "address": place.address.model_dump(exclude_none=True),
        # GeoJSON point – order is [lon, lat]; enables 2dsphere queries ($near, $geoWithin).
        "location": {"type": "Point", "coordinates": [place.coordinates.lon, place.coordinates.lat]},
        "menu": [item.model_dump(exclude_none=True) for item in place.menu],
        "photos": [],
        "created_at": now,
        "updated_at": now,
    }
    # Omit instead of storing null, so the partial unique index skips places without an OSM link.
    if place.osm:
        doc["osm"] = place.osm.model_dump(mode="json")
    return doc


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


async def create_place(db: AsyncDatabase, place: PlaceCreate) -> Place:
    doc = to_document(place)
    try:
        result = await db[COLLECTION].insert_one(doc)
    except DuplicateKeyError as e:
        raise PlaceAlreadyExists from e
    doc["_id"] = result.inserted_id
    return from_document(doc)


async def get_place(db: AsyncDatabase, place_id: str) -> Place | None:
    try:
        oid = ObjectId(place_id)
    except InvalidId:
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
        query["location"] = {
            "$near": {
                "$geometry": {"type": "Point", "coordinates": [near.lon, near.lat]},
                "$maxDistance": radius_m,
            }
        }
    if power_outlets is not None:
        query["amenities.power_outlets"] = power_outlets
    cursor = db[COLLECTION].find(query).skip(skip).limit(limit)
    return [from_document(doc) async for doc in cursor]


class PhotoLimitReached(Exception):
    pass


async def add_photo(db: AsyncDatabase, place_id: str, photo: dict[str, Any], max_photos: int) -> Photo | None:
    """Returns None if the place doesn't exist. Limit check and push happen atomically in one update."""
    try:
        oid = ObjectId(place_id)
    except InvalidId:
        return None
    result = await db[COLLECTION].update_one(
        {"_id": oid, f"photos.{max_photos - 1}": {"$exists": False}},
        {"$push": {"photos": photo}, "$set": {"updated_at": datetime.now(UTC)}},
    )
    if result.matched_count == 0:
        if await db[COLLECTION].count_documents({"_id": oid}, limit=1):
            raise PhotoLimitReached
        return None
    return photo_from_subdocument(photo)


async def remove_photo(db: AsyncDatabase, place_id: str, photo_id: str) -> str | None:
    """Removes the photo entry and returns its storage key, or None if not found."""
    try:
        oid = ObjectId(place_id)
    except InvalidId:
        return None
    doc = await db[COLLECTION].find_one_and_update(
        {"_id": oid, "photos.id": photo_id},
        {"$pull": {"photos": {"id": photo_id}}, "$set": {"updated_at": datetime.now(UTC)}},
        projection={"photos": {"$elemMatch": {"id": photo_id}}},
    )
    return doc["photos"][0]["key"] if doc else None
