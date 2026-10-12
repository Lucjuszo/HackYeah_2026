from typing import Annotated

from bson import ObjectId
from fastapi import Depends, HTTPException, status
from pymongo.asynchronous.database import AsyncDatabase

from app.auth import OptionalUser
from app.db import get_db, parse_object_id
from app.repositories import places

Db = Annotated[AsyncDatabase, Depends(get_db)]


async def visible_place_id(place_id: str, db: Db, user: OptionalUser) -> ObjectId:
    """The place's id, or 404 when it doesn't exist or is waiting for approval and the caller is
    neither its author nor an admin (same answer as for a missing place: nothing leaks)."""
    oid = parse_object_id(place_id)
    if oid is None or not await places.place_visible(db, oid, user):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Place not found")
    return oid


VisiblePlaceId = Annotated[ObjectId, Depends(visible_place_id)]
