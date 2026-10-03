import asyncio
from functools import cache
from pathlib import Path
from typing import Protocol

from app.config import settings


class Storage(Protocol):
    async def save(self, key: str, data: bytes, content_type: str) -> None: ...
    async def delete(self, key: str) -> None: ...
    def url(self, key: str) -> str: ...


class LocalStorage:
    """Files on disk, served by FastAPI under media_base_url. Fine for dev and a single small VPS."""

    def __init__(self, root: str, base_url: str) -> None:
        self.root = Path(root)
        self.base_url = base_url.rstrip("/")

    async def save(self, key: str, data: bytes, content_type: str) -> None:
        path = self.root / key
        await asyncio.to_thread(path.parent.mkdir, parents=True, exist_ok=True)
        await asyncio.to_thread(path.write_bytes, data)

    async def delete(self, key: str) -> None:
        await asyncio.to_thread((self.root / key).unlink, missing_ok=True)

    def url(self, key: str) -> str:
        return f"{self.base_url}/{key}"


@cache
def get_storage() -> Storage:
    return LocalStorage(settings.media_dir, settings.media_base_url)
