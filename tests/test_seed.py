import asyncio

import pytest

from app.config import settings
from app.db import create_client
from scripts import seed
from tests.helpers import EXAMPLES_DIR

PLACE_FILES = len(list((EXAMPLES_DIR / "places").glob("*.json")))
REVIEWS = [review for reviews in seed.REVIEWS.values() for review in reviews]


def run_seed():
    async def go():
        mongo = create_client()
        try:
            return await seed.seed(mongo[settings.mongo_db])
        finally:
            await mongo.close()

    return asyncio.run(go())


def test_every_example_has_review_entry():
    assert set(seed.REVIEWS) == {p.name for p in (EXAMPLES_DIR / "places").glob("*.json")}


def test_seeds_examples_marked_as_mock(db, client):
    removed, seeded = run_seed()

    assert removed == 0
    assert len(seeded) == PLACE_FILES
    assert all(place.is_mock for place in seeded)
    assert db.places.count_documents({"is_mock": True}) == PLACE_FILES
    assert db.ratings.count_documents({"is_mock": True}) == len(REVIEWS)
    assert db.comments.count_documents({"is_mock": True}) == sum(1 for *_, text in REVIEWS if text)

    cafe = next(p for p in seeded if p.name == "Kawiarnia Pod Kodem")
    assert cafe.rating.count == 3
    assert cafe.rating.average == pytest.approx(14 / 3)

    # is_mock is visible through the API too
    api_place = client.get(f"/places/{cafe.id}").json()
    assert api_place["is_mock"] is True
    assert all(c["is_mock"] for c in client.get(f"/places/{cafe.id}/comments").json())


def test_rerun_replaces_mock_data_and_keeps_real_data(db, client, minimal_payload):
    real = client.post("/places", json=minimal_payload).json()
    client.put(f"/places/{real['id']}/ratings/me", json={"score": 3})
    client.post(f"/places/{real['id']}/comments", json={"text": "prawdziwy"})

    first_ids = {p.id for p in run_seed()[1]}
    removed, seeded = run_seed()

    assert removed == PLACE_FILES
    assert first_ids.isdisjoint(p.id for p in seeded)
    assert db.places.count_documents({"is_mock": True}) == PLACE_FILES
    assert db.ratings.count_documents({"is_mock": True}) == len(REVIEWS)

    assert real["is_mock"] is False
    after = client.get(f"/places/{real['id']}").json()
    assert after["rating"] == {"average": 3, "count": 1}
    assert [c["text"] for c in client.get(f"/places/{real['id']}/comments").json()] == ["prawdziwy"]


def test_mock_comments_on_mock_place_by_real_user_are_removed(db, client):
    _, seeded = run_seed()
    place_id = seeded[0].id
    client.post(f"/places/{place_id}/comments", json={"text": "real user on mock place"})

    run_seed()
    assert db.comments.count_documents({"is_mock": False}) == 0
