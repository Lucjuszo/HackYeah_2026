import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pymongo.errors import PyMongoError, ServerSelectionTimeoutError
from starlette.middleware.sessions import SessionMiddleware

from app.auth.tokens import signing_secret
from app.config import settings
from app.db import client, get_db, utcnow
from app.repositories import comments as comments_repo
from app.repositories import places as places_repo
from app.repositories import ratings as ratings_repo
from app.repositories import users as users_repo
from app.geocoding import geocoder
from app.routers import admin, auth, comments, geocode, media, photos, places, privacy, ratings


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
    await geocoder.aclose()
    await client.close()


STARTED_AT = time.monotonic()

app = FastAPI(title="HackYeah 2026", lifespan=lifespan)
# The frontend sends the token in the Authorization header (no cookies), so no allow_credentials.
# X-Total-Count must be exposed explicitly or browsers hide it from JavaScript.
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origin_list(),
    allow_origin_regex=settings.cors_origin_regex(),
    allow_methods=["*"],
    allow_headers=["*"],
    expose_headers=["X-Total-Count"],
    max_age=600,
)
# Only used during OAuth login, to keep the anti-CSRF `state` between /login and /callback.
# same_site="lax" lets the cookie ride along on the provider's top-level redirect back to us.
app.add_middleware(SessionMiddleware, secret_key=signing_secret(), same_site="lax", max_age=600)
app.include_router(auth.router)
app.include_router(places.router)
app.include_router(photos.router)
app.include_router(ratings.router)
app.include_router(comments.router)
app.include_router(media.router)
app.include_router(geocode.router)
app.include_router(admin.router)
app.include_router(privacy.router)


@app.get("/health")
async def health() -> JSONResponse:
    """200 when the database answers, 503 otherwise (load balancers and uptime checks read the status)."""
    try:
        await get_db().command("ping")
    except PyMongoError:
        return JSONResponse({"status": "degraded", "mongo": "unreachable"}, status.HTTP_503_SERVICE_UNAVAILABLE)
    return JSONResponse({"status": "ok", "mongo": "ok"})


@app.get("/health/details", include_in_schema=False)
async def health_details() -> JSONResponse:
    """Like /health, with database latency and uptime. Served to the outside by the frontend's nginx
    under a hidden path (deploy/nginx.conf), which answers by itself when the API is unreachable."""
    started = time.perf_counter()
    try:
        await get_db().command("ping")
        database = {"status": "ok", "latency_ms": round((time.perf_counter() - started) * 1000, 1)}
    except PyMongoError:
        database = {"status": "unreachable", "latency_ms": None}
    ok = database["status"] == "ok"
    body = {
        "status": "ok" if ok else "degraded",
        "checked_at": utcnow().isoformat(),
        "api": {"status": "ok", "uptime_s": int(time.monotonic() - STARTED_AT)},
        "database": database,
    }
    return JSONResponse(body, status.HTTP_200_OK if ok else status.HTTP_503_SERVICE_UNAVAILABLE)
