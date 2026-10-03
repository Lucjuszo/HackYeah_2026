import pytest
from bson import ObjectId

from app.auth import MOCK_USER_ID
from tests.helpers import as_user


def patch(client, place_id, body, user="editor"):
    return client.patch(f"/places/{place_id}", json=body, headers=as_user(user))


def test_create_records_author(client, minimal_payload):
    default = client.post("/places", json=minimal_payload).json()
    assert default["created_by"] == default["updated_by"] == MOCK_USER_ID

    explicit = client.post("/places", json=minimal_payload, headers=as_user("anna")).json()
    assert explicit["created_by"] == "anna"


def test_updates_only_given_fields(client, created_place):
    response = patch(client, created_place["id"], {"name": "Nowa nazwa", "usage_price": "30-60"})
    assert response.status_code == 200, response.text
    updated = response.json()

    assert updated["name"] == "Nowa nazwa"
    assert updated["usage_price"] == "30-60"
    unchanged = {"address", "coordinates", "amenities", "opening_hours", "features", "menu", "created_at", "created_by"}
    assert {k: updated[k] for k in unchanged} == {k: created_place[k] for k in unchanged}


def test_records_editor_and_time(client, created_place):
    updated = patch(client, created_place["id"], {"name": "X"}, user="bartek").json()
    assert updated["updated_by"] == "bartek"
    assert updated["created_by"] == MOCK_USER_ID
    assert updated["updated_at"] >= created_place["updated_at"]


def test_response_matches_stored_place(client, created_place):
    updated = patch(client, created_place["id"], {"atmosphere": "lively"}).json()
    assert client.get(f"/places/{created_place['id']}").json() == updated


def test_amenities_are_merged(client, created_place):
    updated = patch(client, created_place["id"], {"amenities": {"wifi": False, "computer_access": True}}).json()
    expected = {**created_place["amenities"], "wifi": False, "computer_access": True}
    assert updated["amenities"] == expected


def test_amenity_can_be_reset_to_unknown(client, created_place):
    updated = patch(client, created_place["id"], {"amenities": {"wifi": None}}).json()
    assert updated["amenities"]["wifi"] is None
    assert updated["amenities"]["power_outlets"] is True


def test_lists_and_objects_are_replaced(client, created_place):
    body = {
        "features": ["Tylko to"],
        "menu": [{"name": "Woda", "price": 0}],
        "address": {"city": "Gdańsk", "country_code": "pl"},
        "opening_hours": {"always_open": True},
    }
    updated = patch(client, created_place["id"], body).json()
    assert updated["features"] == ["Tylko to"]
    assert updated["menu"] == [{"name": "Woda", "category": None, "description": None, "price": 0, "currency": "PLN"}]
    assert updated["address"]["street"] is None
    assert updated["opening_hours"] == {"always_open": True, "periods": []}


def test_coordinates_update_location(client, created_place, db):
    patch(client, created_place["id"], {"coordinates": {"lat": 52.2297, "lon": 21.0122}})
    doc = db.places.find_one({"_id": ObjectId(created_place["id"])})
    assert doc["location"]["coordinates"] == [21.0122, 52.2297]
    near_warsaw = client.get("/places", params={"lat": 52.2297, "lon": 21.0122, "radius_m": 100}).json()
    assert [p["id"] for p in near_warsaw] == [created_place["id"]]


@pytest.mark.parametrize("field", ["opening_hours", "usage_price", "atmosphere"])
def test_nullable_fields_can_be_cleared(client, created_place, field):
    assert created_place[field] is not None
    assert patch(client, created_place["id"], {field: None}).json()[field] is None


@pytest.mark.parametrize("field", ["name", "address", "coordinates", "amenities", "features", "menu"])
def test_required_fields_cannot_be_nulled(client, created_place, field):
    assert patch(client, created_place["id"], {field: None}).status_code == 422


def test_invalid_values_rejected(client, created_place):
    assert patch(client, created_place["id"], {"atmosphere": "loud"}).status_code == 422
    assert patch(client, created_place["id"], {"coordinates": {"lat": 100, "lon": 0}}).status_code == 422


def test_empty_body_rejected(client, created_place):
    assert patch(client, created_place["id"], {}).status_code == 422


def test_unknown_fields_ignored_but_not_stored(client, created_place):
    response = patch(client, created_place["id"], {"name": "X", "rating": {"average": 5, "count": 999}})
    assert response.status_code == 200
    assert response.json()["rating"] == {"average": None, "count": 0}


class TestOsm:
    def test_link_and_unlink(self, client, created_place, db):
        linked = patch(client, created_place["id"], {"osm": {"type": "node", "id": 7}}).json()
        assert linked["osm"] == {"type": "node", "id": 7}

        unlinked = patch(client, created_place["id"], {"osm": None}).json()
        assert unlinked["osm"] is None
        assert "osm" not in db.places.find_one({"_id": ObjectId(created_place["id"])})

    def test_conflict(self, client, created_place, minimal_payload):
        client.post("/places", json={**minimal_payload, "osm": {"type": "node", "id": 7}})
        response = patch(client, created_place["id"], {"osm": {"type": "node", "id": 7}})
        assert response.status_code == 409


def test_not_found(client):
    assert patch(client, str(ObjectId()), {"name": "X"}).status_code == 404
    assert patch(client, "not-an-id", {"name": "X"}).status_code == 404


@pytest.mark.parametrize("header", ["", "a" * 65, "two words", "x/y"])
def test_invalid_user_header(client, created_place, header):
    assert patch(client, created_place["id"], {"name": "X"}, user=header).status_code == 422
