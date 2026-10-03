"""User ratings + the place's rating summary, kept up to date incrementally.

The summary ({average, count}) on the place document is never recomputed from all ratings.
Each change adjusts it with a weighted average, computed atomically inside a single MongoDB
update (pipeline), so concurrent ratings of the same place can't overwrite each other:

    add score s:        avg' = (avg * n + s) / (n + 1)            n' = n + 1
    change old -> new:  avg' = (avg * n - old + new) / n          n' = n
    remove score old:   avg' = (avg * n - old) / (n - 1)          n' = n - 1   (null when n' = 0)

Ratings and the summary live in two collections; standalone MongoDB has no multi-document
transactions, so a crash between the two writes could leave the summary slightly off.
"""

from typing import Any

from bson import ObjectId
from pymongo import ReturnDocument
from pymongo.asynchronous.database import AsyncDatabase
from pymongo.errors import DuplicateKeyError

from app.db import utcnow
from app.models.place import RatingSummary
from app.models.rating import Rating
from app.repositories import places

COLLECTION = "ratings"

_N = {"$ifNull": ["$rating.count", 0]}
_AVG = {"$ifNull": ["$rating.average", 0]}
_TOTAL = {"$multiply": [_AVG, _N]}  # sum of all scores, reconstructed from the weighted average


async def ensure_indexes(db: AsyncDatabase) -> None:
    await db[COLLECTION].create_index([("place_id", 1), ("user_id", 1)], unique=True)


def _from_document(doc: dict[str, Any]) -> Rating:
    return Rating(
        place_id=str(doc["place_id"]),
        user_id=doc["user_id"],
        score=doc["score"],
        created_at=doc["created_at"],
        updated_at=doc["updated_at"],
    )


async def _update_summary(db: AsyncDatabase, place_id: ObjectId, average: Any, count: Any) -> RatingSummary:
    doc = await db[places.COLLECTION].find_one_and_update(
        {"_id": place_id},
        [{"$set": {"rating": {"average": average, "count": count}}}],
        projection={"rating": 1},
        return_document=ReturnDocument.AFTER,
    )
    return RatingSummary.model_validate(doc["rating"])


def _added(score: int) -> tuple[Any, Any]:
    new_n = {"$add": [_N, 1]}
    return {"$divide": [{"$add": [_TOTAL, score]}, new_n]}, new_n


def _changed(old: int, new: int) -> tuple[Any, Any]:
    return {"$divide": [{"$add": [_TOTAL, new - old]}, _N]}, _N


def _removed(old: int) -> tuple[Any, Any]:
    new_n = {"$subtract": [_N, 1]}
    average = {"$cond": [{"$lte": [new_n, 0]}, None, {"$divide": [{"$subtract": [_TOTAL, old]}, new_n]}]}
    return average, {"$max": [new_n, 0]}


async def get_summary(db: AsyncDatabase, place_id: ObjectId) -> RatingSummary:
    doc = await db[places.COLLECTION].find_one({"_id": place_id}, projection={"rating": 1})
    return RatingSummary.model_validate(doc.get("rating", {}))


async def get_rating(db: AsyncDatabase, place_id: ObjectId, user_id: str) -> Rating | None:
    doc = await db[COLLECTION].find_one({"place_id": place_id, "user_id": user_id})
    return _from_document(doc) if doc else None


async def set_rating(
    db: AsyncDatabase, place_id: ObjectId, user_id: str, score: int
) -> tuple[Rating, RatingSummary]:
    """Creates or replaces the user's rating of the place (one rating per user per place)."""
    now = utcnow()
    for attempt in range(2):
        try:
            previous = await db[COLLECTION].find_one_and_update(
                {"place_id": place_id, "user_id": user_id},
                {"$set": {"score": score, "updated_at": now}, "$setOnInsert": {"created_at": now}},
                upsert=True,
                return_document=ReturnDocument.BEFORE,
            )
            break
        except DuplicateKeyError:
            # Two concurrent first ratings by the same user: the loser retries as an update.
            if attempt:
                raise

    if previous is None:
        summary = await _update_summary(db, place_id, *_added(score))
    elif previous["score"] != score:
        summary = await _update_summary(db, place_id, *_changed(previous["score"], score))
    else:
        summary = await get_summary(db, place_id)

    created_at = previous["created_at"] if previous else now
    rating = Rating(place_id=str(place_id), user_id=user_id, score=score, created_at=created_at, updated_at=now)
    return rating, summary


async def delete_rating(db: AsyncDatabase, place_id: ObjectId, user_id: str) -> RatingSummary | None:
    """Returns the recalculated summary, or None if the user hadn't rated the place."""
    removed = await db[COLLECTION].find_one_and_delete({"place_id": place_id, "user_id": user_id})
    if removed is None:
        return None
    return await _update_summary(db, place_id, *_removed(removed["score"]))
