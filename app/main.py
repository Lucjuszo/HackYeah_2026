from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles

from app.config import settings
from app.db import client, get_db
from app.repositories.places import ensure_indexes
from app.routers import photos, places


@asynccontextmanager
async def lifespan(app: FastAPI):
    await client.aconnect()
    await ensure_indexes(get_db())
    yield
    await client.close()


app = FastAPI(title="HackYeah 2026", lifespan=lifespan)
app.include_router(places.router)
app.include_router(photos.router)
# In prod serve this via nginx/Caddy or a CDN, or switch storage to S3 and drop the mount.
app.mount(settings.media_base_url, StaticFiles(directory=settings.media_dir, check_dir=False), name="media")


@app.get("/health")
async def health():
    await get_db().command("ping")
    return {"status": "ok", "mongo": "ok"}
