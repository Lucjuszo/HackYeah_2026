from typing import Annotated

from bson import ObjectId
from fastapi import Depends, HTTPException, status
from pymongo.asynchronous.database import AsyncDatabase

from app.db import get_db, parse_object_id
from app.repositories import places

Db = Annotated[AsyncDatabase, Depends(get_db)]


async def existing_place_id(place_id: str, db: Db) -> ObjectId:
    oid = parse_object_id(place_id)
    if oid is None or not await places.place_exists(db, oid):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Place not found")
    return oid


ExistingPlaceId = Annotated[ObjectId, Depends(existing_place_id)]
