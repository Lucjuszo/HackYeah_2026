from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles

from app.config import settings
from app.db import client, get_db
from app.repositories import comments as comments_repo
from app.repositories import places as places_repo
from app.repositories import ratings as ratings_repo
from app.routers import comments, photos, places, ratings


@asynccontextmanager
async def lifespan(app: FastAPI):
    await client.aconnect()
    db = get_db()
    for repo in (places_repo, ratings_repo, comments_repo):
        await repo.ensure_indexes(db)
    yield
    await client.close()


app = FastAPI(title="HackYeah 2026", lifespan=lifespan)
app.include_router(places.router)
app.include_router(photos.router)
app.include_router(ratings.router)
app.include_router(comments.router)
# In prod serve this via nginx/Caddy or a CDN, or switch storage to S3 and drop the mount.
# Created up front: StaticFiles answers 500 instead of 404 while the directory doesn't exist.
Path(settings.media_dir).mkdir(parents=True, exist_ok=True)
app.mount(settings.media_base_url, StaticFiles(directory=settings.media_dir), name="media")


@app.get("/health")
async def health():
    await get_db().command("ping")
    return {"status": "ok", "mongo": "ok"}
