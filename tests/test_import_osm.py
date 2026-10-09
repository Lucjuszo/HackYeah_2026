import asyncio
import json

import pytest
from bson import ObjectId

from app.config import settings
from app.db import create_client
from app.models.place import Amenities
from scripts import import_osm
from tests.helpers import as_user

SNAPSHOT_ELEMENTS = json.loads(import_osm.SNAPSHOT.read_text(encoding="utf-8"))["elements"]


def run_import(elements=SNAPSHOT_ELEMENTS, count=10):
    async def go():
        mongo = create_client()
        try:
            return await import_osm.import_places(mongo[settings.mongo_db], elements, count)
        finally:
            await mongo.close()

    return asyncio.run(go())


def by_osm_id(elements):
    return {(e["type"], e["id"]): e for e in elements}


def test_snapshot_is_committed_and_attributed():
    snapshot = json.loads(import_osm.SNAPSHOT.read_text(encoding="utf-8"))
    assert "OpenStreetMap" in snapshot["license"]
    assert len(snapshot["elements"]) > 100


def test_imports_half_cafes_half_restaurants(db):
    _, imported = run_import(count=10)
    assert len(imported) == 10
    kinds = [by_osm_id(SNAPSHOT_ELEMENTS)[(p.osm.type, p.osm.id)]["tags"]["amenity"] for p in imported]
    assert kinds.count("cafe") == 5
    assert kinds.count("restaurant") == 5
    assert len({p.name.casefold() for p in imported}) == 10


def test_real_data_kept_and_mock_fields_listed(db):
    _, imported = run_import(count=10)
    elements = by_osm_id(SNAPSHOT_ELEMENTS)
    for place in imported:
        tags = elements[(place.osm.type, place.osm.id)]["tags"]
        assert place.is_mock is True
        assert place.name == tags["name"]
        assert place.address.street == tags["addr:street"]
        assert place.address.house_number == tags["addr:housenumber"]
        assert {"usage_price", "atmosphere", "menu"} <= set(place.mock_fields)
        # opening hours are real whenever OSM has parseable ones (the import prefers those)
        assert "opening_hours" not in place.mock_fields
        # every amenity is either real or listed as mock
        for flag in Amenities.model_fields:
            assert getattr(place.amenities, flag) is not None
        assert all(f.startswith(("amenities.", "opening_hours", "features", "usage_price", "atmosphere", "menu"))
                   for f in place.mock_fields)


def test_wifi_from_osm_is_not_marked_mock(db):
    _, imported = run_import(count=30)
    elements = by_osm_id(SNAPSHOT_ELEMENTS)
    with_wifi_tag = [p for p in imported if "internet_access" in elements[(p.osm.type, p.osm.id)]["tags"]]
    assert with_wifi_tag, "the snapshot should contain places with internet_access"
    for place in with_wifi_tag:
        assert "amenities.wifi" not in place.mock_fields


def test_reviews_are_mock_and_summaries_match(db):
    _, imported = run_import(count=10)
    assert db.ratings.count_documents({"is_mock": False}) == 0
    assert db.comments.count_documents({"is_mock": False}) == 0
    for place in imported:
        scores = [r["score"] for r in db.ratings.find({"place_id": ObjectId(place.id)})]
        assert place.rating.count == len(scores)
        if scores:
            assert place.rating.average == pytest.approx(sum(scores) / len(scores))


def test_deterministic(db):
    _, first = run_import(count=6)
    _, second = run_import(count=6)
    strip = lambda p: p.model_dump(exclude={"id", "created_at", "updated_at", "approved_at"})  # noqa: E731
    assert [strip(p) for p in first] == [strip(p) for p in second]


def test_rerun_replaces_mock_data(db):
    run_import(count=6)
    removed, imported = run_import(count=6)
    assert removed == 6
    assert db.places.count_documents({}) == 6


def test_skips_osm_element_linked_to_real_place(db, client, minimal_payload):
    _, imported = run_import(count=4)
    taken = imported[0].osm
    run_import(count=0)  # clear mock data
    client.post("/places", json={**minimal_payload, "osm": taken.model_dump(mode="json")}, headers=as_user("anna"))

    _, imported = run_import(count=4)
    assert len(imported) == 4
    assert taken not in [p.osm for p in imported]
    assert db.places.count_documents({"is_mock": False}) == 1


def test_editing_mock_field_makes_it_real(db, client):
    _, imported = run_import(count=2)
    place = imported[0]
    mock_flag = next(f for f in place.mock_fields if f.startswith("amenities."))
    flag = mock_flag.split(".", 1)[1]

    response = client.patch(
        f"/places/{place.id}", json={"usage_price": "0-30", "amenities": {flag: True}}, headers=as_user("anna")
    )
    assert response.status_code == 200, response.text
    remaining = response.json()["mock_fields"]
    assert "usage_price" not in remaining
    assert mock_flag not in remaining
    assert "menu" in remaining
