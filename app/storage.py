import asyncio
from functools import cache
from io import BytesIO
from pathlib import PurePosixPath, Path
from typing import Protocol

import cloudinary.uploader

from app.config import settings


class Storage(Protocol):
    async def save(self, key: str, data: bytes, content_type: str) -> None: ...
    async def delete(self, key: str) -> None: ...
    def path(self, key: str) -> Path | None: ...
    def url(self, key: str) -> str: ...
    def redirect_url(self, key: str, *, download: bool = False) -> str | None: ...


class LocalStorage:
    """Files on disk, served under media_base_url. Fine for dev and a single small VPS."""

    def __init__(self, root: str) -> None:
        self.root = Path(root)

    def path(self, key: str) -> Path | None:
        """Path of the stored file, None if it doesn't exist or the key escapes the media dir ("../")."""
        root = self.root.resolve()
        path = (root / key).resolve()
        if not path.is_relative_to(root) or not path.is_file():
            return None
        return path

    async def save(self, key: str, data: bytes, content_type: str) -> None:
        path = self.root / key
        await asyncio.to_thread(path.parent.mkdir, parents=True, exist_ok=True)
        await asyncio.to_thread(path.write_bytes, data)

    async def delete(self, key: str) -> None:
        await asyncio.to_thread((self.root / key).unlink, missing_ok=True)

    def url(self, key: str) -> str:
        # Absolute when PUBLIC_BASE_URL is set; read per call so a config change needs no new storage.
        return f"{settings.media_url_prefix()}/{key}"

    def redirect_url(self, key: str, *, download: bool = False) -> str | None:
        return None  # served by the API itself (path())


class CloudinaryStorage:
    """Files in a Cloudinary account, delivered straight from its CDN; survives redeploys (Render's disk doesn't).

    Key "places/<id>/<photo>.webp" becomes the asset "<folder>/places/<id>/<photo>" (Cloudinary keeps
    the extension out of public ids). URLs are built locally, without an API call.
    """

    def __init__(self, cloud_name: str, api_key: str, api_secret: str, folder: str = "") -> None:
        self.cloud_name = cloud_name
        self.folder = folder.strip("/")
        self._auth = {"cloud_name": cloud_name, "api_key": api_key, "api_secret": api_secret}

    def public_id(self, key: str) -> str:
        stem = str(PurePosixPath(key).with_suffix(""))
        return f"{self.folder}/{stem}" if self.folder else stem

    def path(self, key: str) -> Path | None:
        return None

    async def save(self, key: str, data: bytes, content_type: str) -> None:
        public_id = self.public_id(key)
        await asyncio.to_thread(
            cloudinary.uploader.upload,
            BytesIO(data),
            public_id=public_id,
            # Shows up in the same folders in the Media Library of accounts with dynamic folders.
            asset_folder=str(PurePosixPath(public_id).parent),
            resource_type="image",
            overwrite=True,
            **self._auth,
        )

    async def delete(self, key: str) -> None:
        # Purges the CDN copy too; a missing asset is reported as "not found", not raised.
        await asyncio.to_thread(
            cloudinary.uploader.destroy, self.public_id(key), resource_type="image", invalidate=True, **self._auth
        )

    def url(self, key: str, *, download: bool = False) -> str:
        suffix = PurePosixPath(key).suffix
        flags = "fl_attachment/" if download else ""
        return f"https://res.cloudinary.com/{self.cloud_name}/image/upload/{flags}{self.public_id(key)}{suffix}"

    def redirect_url(self, key: str, *, download: bool = False) -> str | None:
        return self.url(key, download=download)


@cache
def get_storage() -> Storage:
    credentials = settings.cloudinary_credentials() if settings.storage_backend != "local" else None
    if credentials is not None:
        return CloudinaryStorage(*credentials, folder=settings.cloudinary_folder)
    if settings.storage_backend == "cloudinary":
        raise RuntimeError("STORAGE_BACKEND=cloudinary but CLOUDINARY_URL (or CLOUDINARY_* variables) is not set")
    return LocalStorage(settings.media_dir)
