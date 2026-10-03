import uuid
from datetime import UTC, datetime
from typing import Annotated

from bson import ObjectId
from fastapi import APIRouter, Depends, HTTPException, UploadFile, status
from fastapi.concurrency import run_in_threadpool
from pymongo.asynchronous.database import AsyncDatabase

from app.config import settings
from app.db import get_db
from app.images import InvalidImage, process_image
from app.models.place import Photo
from app.repositories import places as repo
from app.storage import get_storage

router = APIRouter(prefix="/places/{place_id}/photos", tags=["photos"])

Db = Annotated[AsyncDatabase, Depends(get_db)]


@router.post("", status_code=status.HTTP_201_CREATED)
async def upload_photo(place_id: str, file: UploadFile, db: Db) -> Photo:
    # place_id ends up in the storage path, so reject anything that isn't an ObjectId up front.
    if not ObjectId.is_valid(place_id):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Place not found")
    raw =await file.read(settings.max_photo_bytes + 1)
    if len(raw) > settings.max_photo_bytes:
        raise HTTPException(status.HTTP_413_CONTENT_TOO_LARGE, f"Max photo size is {settings.max_photo_bytes} bytes")
    try:
        image = await run_in_threadpool(process_image, raw, settings.max_photo_dimension)
    except InvalidImage:
        raise HTTPException(status.HTTP_415_UNSUPPORTED_MEDIA_TYPE, "File is not a supported image")

    photo_id = uuid.uuid4().hex
    key = f"places/{place_id}/{photo_id}.webp"
    photo = {
        "id": photo_id,
        "key": key,
        "content_type": image.content_type,
        "width": image.width,
        "height": image.height,
        "size": len(image.data),
        "created_at": datetime.now(UTC),
    }

    # File first, then DB entry: a failed DB write never leaves a reference to a missing file.
    storage = get_storage()
    await storage.save(key, image.data, image.content_type)
    try:
        result = await repo.add_photo(db, place_id, photo, settings.max_photos_per_place)
    except repo.PhotoLimitReached:
        await storage.delete(key)
        raise HTTPException(status.HTTP_409_CONFLICT, f"Max {settings.max_photos_per_place} photos per place")
    except Exception:
        await storage.delete(key)
        raise
    if result is None:
        await storage.delete(key)
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Place not found")
    return result


@router.delete("/{photo_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_photo(place_id: str, photo_id: str, db: Db) -> None:
    key = await repo.remove_photo(db, place_id, photo_id)
    if key is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Photo not found")
    await get_storage().delete(key)
