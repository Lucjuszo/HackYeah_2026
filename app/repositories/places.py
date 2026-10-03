import re
from collections.abc import Sequence
from dataclasses import dataclass
from datetime import datetime
from typing import Any

from bson import ObjectId
from pymongo import ReturnDocument
from pymongo.asynchronous.database import AsyncDatabase
from pymongo.errors import DuplicateKeyError

from app.db import parse_object_id, utcnow
from app.models.opening_hours import OpeningHours
from app.models.place import (
    Atmosphere,
    Coordinates,
    MenuItem,
    Photo,
    PhotoVariant,
    Place,
    PlaceCreate,
    PlaceSort,
    PlaceSummary,
    PlaceUpdate,
    parse_usage_price,
)
from app.storage import get_storage

COLLECTION = "places"

# Fields stored exactly as the model dumps them (mode="json" turns enums into plain str/int for BSON).
_PLAIN_FIELDS = {"name", "amenities", "opening_hours", "usage_price", "atmosphere", "features"}


class PlaceAlreadyExists(Exception):
    pass


def _geo_point(coordinates: Coordinates) -> dict[str, Any]:
    # GeoJSON point – order is [lon, lat]; enables 2dsphere queries ($near, $geoWithin).
    return {"type": "Point", "coordinates": [coordinates.lon, coordinates.lat]}


def _price_range(usage_price: str | None) -> dict[str, Any] | None:
    """Stored next to usage_price so price filters are plain indexed queries."""
    parsed = parse_usage_price(usage_price)
    return parsed.model_dump() if parsed else None


def _menu(menu: list[MenuItem]) -> list[dict[str, Any]]:
    return [item.model_dump(exclude_none=True) for item in menu]


def to_document(
    place: PlaceCreate, user_id: str, *, is_mock: bool = False, mock_fields: Sequence[str] = ()
) -> dict[str, Any]:
    now = utcnow()
    doc: dict[str, Any] = {
        **place.model_dump(mode="json", include=_PLAIN_FIELDS),
        "address": place.address.model_dump(exclude_none=True),
        "location": _geo_point(place.coordinates),
        "price_range": _price_range(place.usage_price),
        "menu": _menu(place.menu),
        "photos": [],
        "rating": {"average": None, "count": 0},
        "is_mock": is_mock,
        "mock_fields": list(mock_fields),
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
    # Fields set by an edit hold real data now, so they stop being listed as mock.
    edited = [f for f in fields if f != "amenities"]

    for field, value in update.model_dump(mode="json", include=fields & (_PLAIN_FIELDS - {"amenities"})).items():
        to_set[field] = value
    if "amenities" in fields:
        # Merge flag by flag instead of replacing the whole object.
        for flag, value in update.amenities.model_dump(exclude_unset=True).items():
            to_set[f"amenities.{flag}"] = value
            edited.append(f"amenities.{flag}")
    if "address" in fields:
        to_set["address"] = update.address.model_dump(exclude_none=True)
    if "coordinates" in fields:
        to_set["location"] = _geo_point(update.coordinates)
    if "menu" in fields:
        to_set["menu"] = _menu(update.menu)
    if "usage_price" in fields:
        to_set["price_range"] = _price_range(update.usage_price)
    if "osm" in fields:
        if update.osm:
            to_set["osm"] = update.osm.model_dump(mode="json")
        else:
            to_unset["osm"] = ""  # unset, not null – same reason as in to_document

    operations: dict[str, Any] = {"$set": to_set, "$pull": {"mock_fields": {"$in": edited}}}
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
        is_mock=doc.get("is_mock", False),
        mock_fields=doc.get("mock_fields", []),
        created_by=doc.get("created_by"),
        updated_by=doc.get("updated_by"),
        created_at=doc["created_at"],
        updated_at=doc["updated_at"],
        distance_m=doc.get("distance_m"),
        price_range=doc.get("price_range"),
    )


def photo_from_subdocument(sub: dict[str, Any]) -> Photo:
    # Only storage keys are persisted; URLs depend on the storage backend / CDN in use.
    storage = get_storage()
    thumbnail = sub.get("thumbnail")
    return Photo(
        id=sub["id"],
        url=storage.url(sub["key"]),
        content_type=sub["content_type"],
        width=sub["width"],
        height=sub["height"],
        size=sub["size"],
        thumbnail=PhotoVariant(
            url=storage.url(thumbnail["key"]),
            width=thumbnail["width"],
            height=thumbnail["height"],
            size=thumbnail["size"],
        )
        if thumbnail
        else None,
        uploaded_by=sub.get("uploaded_by"),
        uploaded_by_name=sub.get("uploaded_by_name"),
        created_at=sub["created_at"],
    )


def photo_storage_keys(sub: dict[str, Any]) -> list[str]:
    """Every file stored for a photo (full version + thumbnail)."""
    return [sub["key"]] + ([sub["thumbnail"]["key"]] if sub.get("thumbnail") else [])


async def ensure_indexes(db: AsyncDatabase) -> None:
    places = db[COLLECTION]
    await places.create_index([("location", "2dsphere")])
    await places.create_index(
        [("osm.type", 1), ("osm.id", 1)],
        unique=True,
        partialFilterExpression={"osm.id": {"$exists": True}},
    )
    await places.create_index([("price_range.min", 1), ("price_range.max", 1)])
    await backfill_price_ranges(db)


async def backfill_price_ranges(db: AsyncDatabase) -> int:
    """Fills `price_range` in places stored before it existed. Idempotent; returns how many were updated."""
    updated = 0
    async for doc in db[COLLECTION].find({"price_range": {"$exists": False}}, projection={"usage_price": 1}):
        await db[COLLECTION].update_one(
            {"_id": doc["_id"]}, {"$set": {"price_range": _price_range(doc.get("usage_price"))}}
        )
        updated += 1
    return updated


async def place_exists(db: AsyncDatabase, place_id: ObjectId) -> bool:
    return await db[COLLECTION].count_documents({"_id": place_id}, limit=1) > 0


async def create_place(
    db: AsyncDatabase, place: PlaceCreate, user_id: str, *, is_mock: bool = False, mock_fields: Sequence[str] = ()
) -> Place:
    doc = to_document(place, user_id, is_mock=is_mock, mock_fields=mock_fields)
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


EARTH_RADIUS_M = 6_378_100  # what $centerSphere / $geoNear assume


@dataclass
class BoundingBox:
    south: float
    west: float
    north: float
    east: float

    def polygon(self) -> dict[str, Any]:
        s, w, n, e = self.south, self.west, self.north, self.east
        return {"type": "Polygon", "coordinates": [[[w, s], [e, s], [e, n], [w, n], [w, s]]]}


@dataclass
class PlaceFilter:
    near: Coordinates | None = None
    radius_m: int = 1000
    bbox: BoundingBox | None = None  # visible map area; not combined with `near`
    q: str | None = None
    wifi: bool | None = None
    power_outlets: bool | None = None
    atmosphere: Atmosphere | None = None
    min_rating: float | None = None
    min_price: int | None = None  # price_range.min >= (PLN)
    max_price: int | None = None  # price_range.max <= (PLN); open-ended "60+" never matches
    open_at: datetime | None = None  # local time of the places; None = don't filter by opening hours


def _match(f: PlaceFilter) -> dict[str, Any]:
    """Everything except the distance condition (that one differs between $geoNear and count)."""
    query: dict[str, Any] = {}
    if f.q:
        pattern = {"$regex": re.escape(f.q.strip()), "$options": "i"}
        query["$or"] = [{"name": pattern}, {"address.street": pattern}]
    if f.wifi is not None:
        query["amenities.wifi"] = f.wifi
    if f.power_outlets is not None:
        query["amenities.power_outlets"] = f.power_outlets
    if f.atmosphere is not None:
        query["atmosphere"] = str(f.atmosphere)
    if f.min_rating is not None:
        query["rating.average"] = {"$gte": f.min_rating}
    if f.min_price is not None:
        query["price_range.min"] = {"$gte": f.min_price}
    if f.max_price is not None:
        query["price_range.max"] = {"$lte": f.max_price}  # null (open-ended / unknown) never matches
    if f.open_at is not None:
        hhmm = f.open_at.strftime("%H:%M")
        query["$and"] = [
            {
                "$or": [
                    {"opening_hours.always_open": True},
                    {
                        "opening_hours.periods": {
                            "$elemMatch": {"day": f.open_at.weekday(), "open": {"$lte": hhmm}, "close": {"$gt": hhmm}}
                        }
                    },
                ]
            }
        ]
    return query


_SORTS: dict[PlaceSort, dict[str, int]] = {
    PlaceSort.RATING: {"rating.average": -1, "rating.count": -1, "_id": 1},
    PlaceSort.NAME: {"name": 1, "_id": 1},
    PlaceSort.NEWEST: {"_id": -1},
    PlaceSort.OLDEST: {"_id": 1},
}


async def search_places(
    db: AsyncDatabase, f: PlaceFilter, *, sort: PlaceSort | None = None, limit: int = 50, skip: int = 0
) -> tuple[list[dict[str, Any]], int]:
    """Raw documents of one page (with `distance_m` when searching near a point) and the total match count.

    Default order: by distance when `near` is given, oldest first otherwise.
    """
    match = _match(f)
    if f.near:
        sort = sort or PlaceSort.DISTANCE
        pipeline: list[dict[str, Any]] = [
            {
                "$geoNear": {
                    "near": _geo_point(f.near),
                    "distanceField": "distance_m",
                    "maxDistance": f.radius_m,
                    "query": match,
                    "spherical": True,
                }
            }
        ]
        count_query = {
            **match,
            "location": {
                "$geoWithin": {"$centerSphere": [[f.near.lon, f.near.lat], f.radius_m / EARTH_RADIUS_M]}
            },
        }
    else:
        if sort == PlaceSort.DISTANCE:
            raise ValueError("sort=distance needs lat and lon")
        sort = sort or PlaceSort.OLDEST
        if f.bbox:
            match = {**match, "location": {"$geoWithin": {"$geometry": f.bbox.polygon()}}}
        pipeline = [{"$match": match}]
        count_query = match
    if sort != PlaceSort.DISTANCE:  # $geoNear already returns closest first
        pipeline.append({"$sort": _SORTS[sort]})
    pipeline += [{"$skip": skip}, {"$limit": limit}]

    cursor = await db[COLLECTION].aggregate(pipeline)
    docs = await cursor.to_list()
    total = await db[COLLECTION].count_documents(count_query)
    return docs, total


def summary_from_document(doc: dict[str, Any], now: datetime) -> PlaceSummary:
    lon, lat = doc["location"]["coordinates"]
    photos = doc.get("photos", [])
    first = photo_from_subdocument(photos[0]) if photos else None
    hours = doc.get("opening_hours")
    status = OpeningHours.model_validate(hours).status_at(now) if hours else None
    return PlaceSummary(
        id=str(doc["_id"]),
        name=doc["name"],
        address=doc["address"],
        coordinates=Coordinates(lat=lat, lon=lon),
        amenities=doc.get("amenities", {}),
        usage_price=doc.get("usage_price"),
        price_range=doc.get("price_range"),
        atmosphere=doc.get("atmosphere"),
        rating=doc.get("rating", {}),
        thumbnail_url=(first.thumbnail.url if first.thumbnail else first.url) if first else None,
        photo_count=len(photos),
        open_now=status.open_now if status else None,
        closes_at=status.closes_at if status else None,
        opens_at=status.opens_at if status else None,
        is_mock=doc.get("is_mock", False),
        distance_m=doc.get("distance_m"),
    )


async def delete_place(db: AsyncDatabase, place_id: str) -> list[str] | None:
    """Deletes the place with its ratings and comments; returns the storage keys of its photos, None if not found."""
    oid = parse_object_id(place_id)
    if oid is None:
        return None
    doc = await db[COLLECTION].find_one_and_delete({"_id": oid}, projection={"photos": 1})
    if doc is None:
        return None
    # Imported here: both modules import this one.
    from app.repositories import comments, ratings

    await db[ratings.COLLECTION].delete_many({"place_id": oid})
    await db[comments.COLLECTION].delete_many({"place_id": oid})
    return [key for photo in doc.get("photos", []) for key in photo_storage_keys(photo)]


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


async def list_photos(db: AsyncDatabase, place_id: str) -> list[Photo] | None:
    """Photos of a place in upload order, None if the place doesn't exist."""
    oid = parse_object_id(place_id)
    if oid is None:
        return None
    doc = await db[COLLECTION].find_one({"_id": oid}, projection={"photos": 1})
    return [photo_from_subdocument(sub) for sub in doc.get("photos", [])] if doc else None


async def get_photo_subdocument(db: AsyncDatabase, place_id: str, photo_id: str) -> dict[str, Any] | None:
    """The raw stored entry (with storage keys), None if the place or photo doesn't exist."""
    oid = parse_object_id(place_id)
    if oid is None:
        return None
    doc = await db[COLLECTION].find_one(
        {"_id": oid, "photos.id": photo_id}, projection={"photos": {"$elemMatch": {"id": photo_id}}}
    )
    return doc["photos"][0] if doc else None


async def get_photo(db: AsyncDatabase, place_id: str, photo_id: str) -> Photo | None:
    sub = await get_photo_subdocument(db, place_id, photo_id)
    return photo_from_subdocument(sub) if sub else None


async def remove_photo(db: AsyncDatabase, place_id: str, photo_id: str) -> list[str] | None:
    """Removes the photo entry and returns its storage keys, or None if not found."""
    oid = parse_object_id(place_id)
    if oid is None:
        return None
    doc = await db[COLLECTION].find_one_and_update(
        {"_id": oid, "photos.id": photo_id},
        {"$pull": {"photos": {"id": photo_id}}, "$set": {"updated_at": utcnow()}},
        projection={"photos": {"$elemMatch": {"id": photo_id}}},
    )
    return photo_storage_keys(doc["photos"][0]) if doc else None

