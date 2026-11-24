import asyncio

from app.config import settings
from app.db import create_client
from scripts import seed


def run_seed():
    async def go():
        mongo = create_client()
        try:
            return await seed.seed(mongo[settings.mongo_db])
        finally:
            await mongo.close()

    return asyncio.run(go())


def test_seed_only_loads_verified_libraries_and_preserves_reviews(db, client):
    first = run_seed()
    assert {p.name for p in first} == {"Biblioteka Manhattan", "Biblioteka pod Żółwiem", "Biblioteka Lawendowa"}
    assert all(p.address.city == "Gdańsk" and not p.is_mock for p in first)
    url = f"/places/{first[0].id}/comments"
    assert client.post(url, json={"text": "Moja opinia", "score": 4}).status_code == 201
    assert [p.id for p in run_seed()] == [p.id for p in first]
    assert [c["text"] for c in client.get(url).json()] == ["Moja opinia"]


def test_only_legacy_seeded_fakes_leave_the_public_map(db, client, minimal_payload):
    name = "Kawiarnia Pod Kodem"
    genuine = client.post("/places", json={**minimal_payload, "name": name}).json()
    legacy = db.places.find_one({"name": name})
    del legacy["_id"]
    legacy.update(created_by="seed", is_mock=True)
    fake_id = db.places.insert_one(legacy).inserted_id
    run_seed()
    assert db.places.find_one({"_id": fake_id})["approved"] is False
    assert [p["id"] for p in client.get("/places/summary", params={"q": name}).json()] == [genuine["id"]]
