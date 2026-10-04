from typing import Any

from bson import ObjectId
from pymongo import ReturnDocument
from pymongo.asynchronous.database import AsyncDatabase

from app.db import parse_object_id, utcnow
from app.models.comment import Comment
from app.models.user import AuthUser

COLLECTION = "comments"


class CommentNotFound(Exception):
    pass


class NotAllowed(Exception):
    pass


async def ensure_indexes(db: AsyncDatabase) -> None:
    await db[COLLECTION].create_index([("place_id", 1), ("created_at", -1)])
    await db[COLLECTION].create_index([("place_id", 1), ("likes", -1), ("created_at", -1)])


def _from_document(doc: dict[str, Any]) -> Comment:
    return Comment(
        id=str(doc["_id"]),
        place_id=str(doc["place_id"]),
        user_id=doc["user_id"],
        user_name=doc.get("user_name"),
        text=doc["text"],
        is_mock=doc.get("is_mock", False),
        created_at=doc["created_at"],
        edited_at=doc.get("edited_at"),
        edited_by=doc.get("edited_by"),
        likes=doc.get("likes", 0),
        liked_by=doc.get("liked_by", []),
    )


async def create_comment(
    db: AsyncDatabase,
    place_id: ObjectId,
    user_id: str,
    text: str,
    *,
    user_name: str | None = None,
    is_mock: bool = False,
) -> Comment:
    doc = {
        "place_id": place_id,
        "user_id": user_id,
        "user_name": user_name,
        "text": text,
        "is_mock": is_mock,
        "created_at": utcnow(),
    }
    result = await db[COLLECTION].insert_one(doc)
    doc["_id"] = result.inserted_id
    return _from_document(doc)


async def count_comments(db: AsyncDatabase, place_id: ObjectId) -> int:
    return await db[COLLECTION].count_documents({"place_id": place_id})


async def list_comments(db: AsyncDatabase, place_id: ObjectId, *, limit: int, skip: int) -> list[Comment]:
    # Most liked first (older comments without the field count as 0), then newest;
    # _id breaks ties between comments created in the same millisecond.
    order = [("likes", -1), ("created_at", -1), ("_id", -1)]
    cursor = db[COLLECTION].find({"place_id": place_id}).sort(order).skip(skip).limit(limit)
    return [_from_document(doc) async for doc in cursor]


async def _modifiable(db: AsyncDatabase, place_id: ObjectId, comment_id: str, actor: AuthUser) -> dict[str, Any]:
    """The comment's filter, if it exists and the actor is its author or an admin."""
    oid = parse_object_id(comment_id)
    doc = await db[COLLECTION].find_one({"_id": oid, "place_id": place_id}) if oid else None
    if doc is None:
        raise CommentNotFound
    if not (actor.is_admin or doc["user_id"] == actor.id):
        raise NotAllowed
    return {"_id": oid, "place_id": place_id}


async def update_comment(
    db: AsyncDatabase, place_id: ObjectId, comment_id: str, text: str, actor: AuthUser
) -> Comment:
    query = await _modifiable(db, place_id, comment_id, actor)
    doc = await db[COLLECTION].find_one_and_update(
        query,
        {"$set": {"text": text, "edited_at": utcnow(), "edited_by": actor.id}},
        return_document=ReturnDocument.AFTER,
    )
    if doc is None:  # deleted in the meantime
        raise CommentNotFound
    return _from_document(doc)


async def delete_comment(db: AsyncDatabase, place_id: ObjectId, comment_id: str, actor: AuthUser) -> None:
    query = await _modifiable(db, place_id, comment_id, actor)
    await db[COLLECTION].delete_one(query)


async def set_like(db: AsyncDatabase, place_id: ObjectId, comment_id: str, user_id: str, liked: bool) -> Comment:
    """Gives or takes back the user's thumbs up; idempotent, so `likes` always equals len(liked_by)."""
    oid = parse_object_id(comment_id)
    if oid is None:
        raise CommentNotFound
    query = {"_id": oid, "place_id": place_id}
    if liked:
        condition = {"liked_by": {"$ne": user_id}}
        update = {"$push": {"liked_by": user_id}, "$inc": {"likes": 1}}
    else:
        condition = {"liked_by": user_id}
        update = {"$pull": {"liked_by": user_id}, "$inc": {"likes": -1}}
    doc = await db[COLLECTION].find_one_and_update({**query, **condition}, update, return_document=ReturnDocument.AFTER)
    if doc is None:  # already in the requested state, or no such comment
        doc = await db[COLLECTION].find_one(query)
    if doc is None:
        raise CommentNotFound
    return _from_document(doc)
