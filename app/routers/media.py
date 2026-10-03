"""Public photo files: GET {MEDIA_BASE_URL}/{key}, the `url` of every photo and thumbnail.

Anyone can read (no login) – the frontend loads images straight from here. Writing only happens
through the authenticated photo endpoints. Keys are never reused for different content, so the
response may be cached forever by browsers and CDNs. In prod nginx/Caddy can serve MEDIA_DIR instead.
"""

from fastapi import APIRouter, HTTPException, status
from fastapi.responses import FileResponse

from app.config import settings
from app.storage import get_storage

router = APIRouter(prefix=settings.media_base_url.rstrip("/"), tags=["media"])

CACHE_HEADERS = {"Cache-Control": "public, max-age=31536000, immutable"}


@router.get("/{key:path}", include_in_schema=False)
async def media(key: str) -> FileResponse:
    path = get_storage().path(key)
    if path is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Not Found")
    return FileResponse(path, headers=CACHE_HEADERS)
