import json
import os
import shutil
import tempfile
from pathlib import Path

# Settings are read at import time, so point the app at the docker compose container, a test DB
# and a throwaway media dir before anything from `app` is imported. Forced (not setdefault):
# the test DB gets dropped afterwards, so tests must never reach the remote database.
# MONGO_URI (the container's address) may still come from the environment, e.g. in CI.
# Ignore the developer's .env completely: everything the tests need is set right here.
os.environ["HACKYEAH_ENV_FILE"] = ""
os.environ["USE_REMOTE_MONGO"] = "false"
os.environ["MONGO_DB"] = "hackyeah_test"
os.environ["MEDIA_DIR"] = tempfile.mkdtemp(prefix="hackyeah-media-")
# Auth: fixed secret, fake (never contacted) OAuth apps so both providers are "configured",
# dev login off (tests that need it switch it on) and no frontend redirect.
os.environ["JWT_SECRET"] = "test-secret-not-for-production-use-0123456789"
os.environ["GITHUB_CLIENT_ID"] = "test-github-client"
os.environ["GITHUB_CLIENT_SECRET"] = "test-github-secret"
os.environ["GOOGLE_CLIENT_ID"] = "test-google-client"
os.environ["GOOGLE_CLIENT_SECRET"] = "test-google-secret"
os.environ["ADMIN_EMAILS"] = "boss@example.com"
os.environ["AUTH_DEV_LOGIN"] = "false"
os.environ.pop("AUTH_REDIRECT_URL", None)

import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
from pymongo import MongoClient  # noqa: E402

from app.config import settings  # noqa: E402
from app.main import app  # noqa: E402
from app.repositories import comments, places, ratings, users  # noqa: E402
from app.routers.comments import comment_limiter  # noqa: E402
from app.routers.photos import upload_limiter  # noqa: E402

from tests.helpers import DEFAULT_USER, EXAMPLES_DIR, MEDIA_DIR, as_user  # noqa: E402

EXAMPLE_PLACE = EXAMPLES_DIR / "places" / "01-kawiarnia-pod-kodem.json"


@pytest.fixture(scope="session")
def client():
    # One client for the whole session: the async Mongo client is bound to the event loop
    # TestClient runs the app on, and the lifespan (connect + indexes) should run once.
    # Requests are authenticated as DEFAULT_USER unless a test passes its own Authorization header.
    with TestClient(app, headers=as_user(DEFAULT_USER)) as c:
        yield c
    shutil.rmtree(MEDIA_DIR, ignore_errors=True)


@pytest.fixture(scope="session")
def db():
    """Sync client for setting up and asserting on raw DB state, independent of the app's event loop."""
    assert not settings.use_remote_mongo, "tests would drop a database on the remote MongoDB"
    mongo = MongoClient(settings.mongo_uri, tz_aware=True)
    yield mongo[settings.mongo_db]
    mongo.drop_database(settings.mongo_db)
    mongo.close()


@pytest.fixture(autouse=True)
def _clean_state(request):
    # Only tests that touch the app or DB need cleanup; pure unit tests run without Mongo.
    uses_db = "db" in request.fixturenames or "client" in request.fixturenames
    database = request.getfixturevalue("db") if uses_db else None
    yield
    for limiter in (upload_limiter, comment_limiter):
        limiter.reset()
    if database is not None:
        for collection in (places.COLLECTION, ratings.COLLECTION, comments.COLLECTION, users.COLLECTION):
            database[collection].delete_many({})  # keep indexes, drop data
    # Empty the media dir but keep it (created once by mkdtemp above).
    for entry in MEDIA_DIR.iterdir():
        if entry.is_dir():
            shutil.rmtree(entry)
        else:
            entry.unlink()


@pytest.fixture
def place_payload() -> dict:
    return json.loads(EXAMPLE_PLACE.read_text(encoding="utf-8"))


@pytest.fixture
def minimal_payload() -> dict:
    return {
        "name": "Biblioteka",
        "address": {"city": "Kraków", "country_code": "pl"},
        "coordinates": {"lat": 50.0617, "lon": 19.9373},
    }


@pytest.fixture
def created_place(client, place_payload) -> dict:
    response = client.post("/places", json=place_payload)
    assert response.status_code == 201, response.text
    return response.json()
