from typing import Any

from bson import ObjectId
from pymongo.asynchronous.database import AsyncDatabase

from app.db import parse_object_id, utcnow
from app.models.comment import Comment

COLLECTION = "comments"


class CommentNotFound(Exception):
    pass


class NotCommentAuthor(Exception):
    pass


async def ensure_indexes(db: AsyncDatabase) -> None:
    await db[COLLECTION].create_index([("place_id", 1), ("created_at", -1)])


def _from_document(doc: dict[str, Any]) -> Comment:
    return Comment(
        id=str(doc["_id"]),
        place_id=str(doc["place_id"]),
        user_id=doc["user_id"],
        text=doc["text"],
        is_mock=doc.get("is_mock", False),
        created_at=doc["created_at"],
    )


async def create_comment(
    db: AsyncDatabase, place_id: ObjectId, user_id: str, text: str, *, is_mock: bool = False
) -> Comment:
    doc = {"place_id": place_id, "user_id": user_id, "text": text, "is_mock": is_mock, "created_at": utcnow()}
    result = await db[COLLECTION].insert_one(doc)
    doc["_id"] = result.inserted_id
    return _from_document(doc)


async def list_comments(db: AsyncDatabase, place_id: ObjectId, *, limit: int, skip: int) -> list[Comment]:
    # Newest first; _id breaks ties between comments created in the same millisecond.
    cursor = db[COLLECTION].find({"place_id": place_id}).sort([("created_at", -1), ("_id", -1)]).skip(skip).limit(limit)
    return [_from_document(doc) async for doc in cursor]


async def delete_comment(db: AsyncDatabase, place_id: ObjectId, comment_id: str, user_id: str) -> None:
    oid = parse_object_id(comment_id)
    doc = await db[COLLECTION].find_one({"_id": oid, "place_id": place_id}) if oid else None
    if doc is None:
        raise CommentNotFound
    if doc["user_id"] != user_id:
        raise NotCommentAuthor
    await db[COLLECTION].delete_one({"_id": oid, "user_id": user_id})
