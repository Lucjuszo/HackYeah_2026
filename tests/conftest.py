import json
import os
import shutil
import tempfile
from pathlib import Path

# Settings are read at import time, so point the app at a test DB and a throwaway media dir
# before anything from `app` is imported. Real env vars (e.g. MONGO_URI in CI) still win.
os.environ.setdefault("MONGO_DB", "hackyeah_test")
os.environ["MEDIA_DIR"] = tempfile.mkdtemp(prefix="hackyeah-media-")

import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
from pymongo import MongoClient  # noqa: E402

from app.config import settings  # noqa: E402
from app.main import app  # noqa: E402
from app.repositories import comments, places, ratings  # noqa: E402

from tests.helpers import EXAMPLES_DIR, MEDIA_DIR  # noqa: E402

EXAMPLE_PLACE = EXAMPLES_DIR / "places" / "01-kawiarnia-pod-kodem.json"


@pytest.fixture(scope="session")
def client():
    # One client for the whole session: the async Mongo client is bound to the event loop
    # TestClient runs the app on, and the lifespan (connect + indexes) should run once.
    with TestClient(app) as c:
        yield c
    shutil.rmtree(MEDIA_DIR, ignore_errors=True)


@pytest.fixture(scope="session")
def db():
    """Sync client for setting up and asserting on raw DB state, independent of the app's event loop."""
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
    if database is not None:
        for collection in (places.COLLECTION, ratings.COLLECTION, comments.COLLECTION):
            database[collection].delete_many({})  # keep indexes, drop data
    # Empty the media dir but keep it: the app creates it once at startup.
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
