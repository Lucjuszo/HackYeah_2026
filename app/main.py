from contextlib import asynccontextmanager

from fastapi import FastAPI
from pymongo.errors import ServerSelectionTimeoutError
from starlette.middleware.sessions import SessionMiddleware

from app.auth.tokens import signing_secret
from app.config import settings
from app.db import client, get_db
from app.repositories import comments as comments_repo
from app.repositories import places as places_repo
from app.repositories import ratings as ratings_repo
from app.repositories import users as users_repo
from app.routers import auth, comments, media, photos, places, ratings


@asynccontextmanager
async def lifespan(app: FastAPI):
    await client.aconnect()
    db = get_db()
    try:
        for repo in (places_repo, ratings_repo, comments_repo, users_repo):
            await repo.ensure_indexes(db)
    except ServerSelectionTimeoutError as e:
        hint = (
            "MongoDB Atlas usually refuses connections from IPs missing in Security -> Network Access "
            "(add your current IP there), or set USE_REMOTE_MONGO=false and run `docker compose up -d`."
            if settings.use_remote_mongo
            else "Is the container running? `docker compose up -d`"
        )
        raise RuntimeError(f"Cannot reach MongoDB ({settings.mongo_target()}). {hint}") from e
    yield
    await client.close()


app = FastAPI(title="HackYeah 2026", lifespan=lifespan)
# Only used during OAuth login, to keep the anti-CSRF `state` between /login and /callback.
# same_site="lax" lets the cookie ride along on the provider's top-level redirect back to us.
app.add_middleware(SessionMiddleware, secret_key=signing_secret(), same_site="lax", max_age=600)
app.include_router(auth.router)
app.include_router(places.router)
app.include_router(photos.router)
app.include_router(ratings.router)
app.include_router(comments.router)
app.include_router(media.router)


@app.get("/health")
async def health():
    await get_db().command("ping")
    return {"status": "ok", "mongo": "ok"}
