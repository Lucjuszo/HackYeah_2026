import uuid
from enum import StrEnum

from bson import ObjectId
from fastapi import APIRouter, HTTPException, UploadFile, status
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import FileResponse

from app.auth import CurrentUser
from app.config import settings
from app.db import utcnow
from app.images import InvalidImage, process_photo
from app.models.place import Photo
from app.repositories import places as repo
from app.routers.deps import Db
from app.storage import get_storage

router = APIRouter(prefix="/places/{place_id}/photos", tags=["photos"])


class PhotoSize(StrEnum):
    FULL = "full"
    THUMBNAIL = "thumbnail"


async def _delete_files(keys: list[str]) -> None:
    storage = get_storage()
    for key in keys:
        await storage.delete(key)


@router.post("", status_code=status.HTTP_201_CREATED)
async def upload_photo(place_id: str, file: UploadFile, db: Db, user: CurrentUser) -> Photo:
    """Stores two versions: full (longer side <= MAX_PHOTO_DIMENSION) and a thumbnail (<= THUMBNAIL_DIMENSION)."""
    # place_id ends up in storage paths, so reject anything that isn't an ObjectId up front.
    if not ObjectId.is_valid(place_id) or not await repo.place_exists(db, ObjectId(place_id)):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Place not found")
    raw = await file.read(settings.max_photo_bytes + 1)
    if len(raw) > settings.max_photo_bytes:
        raise HTTPException(status.HTTP_413_CONTENT_TOO_LARGE, f"Max photo size is {settings.max_photo_bytes} bytes")
    try:
        photo = await run_in_threadpool(
            process_photo, raw,
            full_dimension=settings.max_photo_dimension, thumbnail_dimension=settings.thumbnail_dimension,
        )
    except InvalidImage:
        raise HTTPException(status.HTTP_415_UNSUPPORTED_MEDIA_TYPE, "File is not a supported image")

    photo_id = uuid.uuid4().hex
    full_key = f"places/{place_id}/{photo_id}.webp"
    thumb_key = f"places/{place_id}/{photo_id}_thumb.webp"
    document = {
        "id": photo_id,
        "key": full_key,
        "content_type": photo.full.content_type,
        "width": photo.full.width,
        "height": photo.full.height,
        "size": len(photo.full.data),
        "thumbnail": {
            "key": thumb_key,
            "width": photo.thumbnail.width,
            "height": photo.thumbnail.height,
            "size": len(photo.thumbnail.data),
        },
        "uploaded_by": user.id,
        "created_at": utcnow(),
    }

    # Files first, then the DB entry: a failed DB write never leaves a reference to a missing file.
    storage = get_storage()
    await storage.save(full_key, photo.full.data, photo.full.content_type)
    await storage.save(thumb_key, photo.thumbnail.data, photo.thumbnail.content_type)
    keys = [full_key, thumb_key]
    try:
        result = await repo.add_photo(db, place_id, document, settings.max_photos_per_place)
    except repo.PhotoLimitReached:
        await _delete_files(keys)
        raise HTTPException(status.HTTP_409_CONFLICT, f"Max {settings.max_photos_per_place} photos per place")
    except Exception:
        await _delete_files(keys)
        raise
    if result is None:  # place deleted in the meantime
        await _delete_files(keys)
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Place not found")
    return result


@router.get("")
async def list_photos(place_id: str, db: Db) -> list[Photo]:
    photos = await repo.list_photos(db, place_id)
    if photos is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Place not found")
    return photos


@router.get("/{photo_id}")
async def get_photo(place_id: str, photo_id: str, db: Db) -> Photo:
    photo = await repo.get_photo(db, place_id, photo_id)
    if photo is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Photo not found")
    return photo


@router.get(
    "/{photo_id}/file",
    response_class=FileResponse,
    responses={200: {"content": {"image/webp": {}}, "description": "The image"}},
)
async def download_photo(
    place_id: str, photo_id: str, db: Db, size: PhotoSize = PhotoSize.FULL, download: bool = False
) -> FileResponse:
    """The image itself. `download=true` makes browsers save it as a file instead of displaying it."""
    sub = await repo.get_photo_subdocument(db, place_id, photo_id)
    if sub is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Photo not found")
    # Photos uploaded before thumbnails existed only have the full version.
    key = sub["thumbnail"]["key"] if size == PhotoSize.THUMBNAIL and sub.get("thumbnail") else sub["key"]
    path = get_storage().path(key)
    if path is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Photo file not found")
    suffix = "_thumb" if size == PhotoSize.THUMBNAIL else ""
    return FileResponse(
        path,
        media_type=sub["content_type"],
        filename=f"{photo_id}{suffix}.webp",
        content_disposition_type="attachment" if download else "inline",
    )


@router.delete("/{photo_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_photo(place_id: str, photo_id: str, db: Db, user: CurrentUser) -> None:
    """The uploader or an admin only."""
    photo = await repo.get_photo(db, place_id, photo_id)
    if photo is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Photo not found")
    if not (user.is_admin or photo.uploaded_by == user.id):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Only the uploader or an admin can delete this photo")
    keys = await repo.remove_photo(db, place_id, photo_id)
    if keys is None:  # removed in the meantime
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Photo not found")
    await _delete_files(keys)
