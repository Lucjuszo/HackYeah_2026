import pytest
from bson import ObjectId

from app.config import settings
from tests.helpers import ANONYMOUS, as_admin, as_user

ADMIN = as_admin()


@pytest.fixture(autouse=True)
def _require_approval(monkeypatch):
    monkeypatch.setattr(settings, "places_require_approval", True)


@pytest.fixture
def pending(client, minimal_payload) -> dict:
    response = client.post("/places", json=minimal_payload)
    assert response.status_code == 201, response.text
    return response.json()


def summary_ids(client) -> list[str]:
    return [p["id"] for p in client.get("/places/summary").json()]


class TestNewPlaces:
    def test_user_place_waits_for_approval(self, client, pending, db):
        assert pending["approved"] is False
        assert pending["approved_by"] is None
        assert db.places.find_one({"_id": ObjectId(pending["id"])})["approved"] is False

    def test_admin_place_is_approved_at_once(self, client, minimal_payload):
        body = client.post("/places", json=minimal_payload, headers=ADMIN).json()
        assert body["approved"] is True
        assert body["approved_by"] == "admin"
        assert pending_ids(client) == []

    def test_pending_hidden_from_searches(self, client, pending):
        assert summary_ids(client) == []
        response = client.get("/places")
        assert response.json() == []
        assert response.headers["X-Total-Count"] == "0"

    def test_pending_visible_to_author_and_admin_only(self, client, pending):
        url = f"/places/{pending['id']}"
        assert client.get(url).status_code == 200  # the author (default test user)
        assert client.get(url, headers=ADMIN).status_code == 200
        assert client.get(url, headers=as_user("someone-else")).status_code == 404
        assert client.get(url, headers=ANONYMOUS).status_code == 404

    def test_places_from_before_approvals_stay_public(self, client, db, minimal_payload):
        from app.db import get_db
        from app.repositories.places import backfill_approved

        pid = client.post("/places", json=minimal_payload, headers=ADMIN).json()["id"]
        db.places.update_one({"_id": ObjectId(pid)}, {"$unset": {"approved": ""}})
        assert client.get(f"/places/{pid}", headers=ANONYMOUS).json()["approved"] is True
        assert summary_ids(client) == []  # not matched until the backfill runs at startup
        assert client.portal.call(backfill_approved, get_db()) == 1
        assert summary_ids(client) == [pid]
        assert client.portal.call(backfill_approved, get_db()) == 0  # idempotent


def pending_ids(client) -> list[str]:
    return [p["id"] for p in client.get("/admin/places", headers=ADMIN).json()]


class TestAdminList:
    def test_lists_pending_newest_first(self, client, minimal_payload):
        first = client.post("/places", json=minimal_payload).json()
        second = client.post("/places", json={**minimal_payload, "name": "Druga"}).json()
        response = client.get("/admin/places", headers=ADMIN)
        assert response.status_code == 200
        assert [p["id"] for p in response.json()] == [second["id"], first["id"]]
        assert response.headers["X-Total-Count"] == "2"

    def test_lists_approved(self, client, pending, minimal_payload):
        public = client.post("/places", json=minimal_payload, headers=ADMIN).json()
        ids = [p["id"] for p in client.get("/admin/places?approved=true", headers=ADMIN).json()]
        assert ids == [public["id"]]

    def test_search_by_name(self, client, minimal_payload):
        client.post("/places", json={**minimal_payload, "name": "Kawiarnia Ala"})
        client.post("/places", json={**minimal_payload, "name": "Biblioteka"})
        names = [p["name"] for p in client.get("/admin/places?q=ala", headers=ADMIN).json()]
        assert names == ["Kawiarnia Ala"]

    def test_admins_only(self, client):
        assert client.get("/admin/places").status_code == 403
        assert client.get("/admin/places", headers=ANONYMOUS).status_code == 401


class TestApproval:
    def test_approve_publishes(self, client, pending):
        response = client.put(f"/admin/places/{pending['id']}/approval", json={"approved": True}, headers=ADMIN)
        assert response.status_code == 200
        body = response.json()
        assert body["approved"] is True
        assert body["approved_by"] == "admin"
        assert body["approved_at"] is not None
        assert summary_ids(client) == [pending["id"]]
        assert client.get(f"/places/{pending['id']}", headers=ANONYMOUS).status_code == 200
        assert pending_ids(client) == []

    def test_unapprove_hides_again(self, client, pending):
        url = f"/admin/places/{pending['id']}/approval"
        client.put(url, json={"approved": True}, headers=ADMIN)
        body = client.put(url, json={"approved": False}, headers=ADMIN).json()
        assert body["approved"] is False
        assert body["approved_at"] is None
        assert summary_ids(client) == []
        assert pending_ids(client) == [pending["id"]]

    def test_reject_deletes(self, client, pending):
        assert client.delete(f"/places/{pending['id']}", headers=ADMIN).status_code == 204
        assert pending_ids(client) == []

    def test_admins_only(self, client, pending):
        url = f"/admin/places/{pending['id']}/approval"
        assert client.put(url, json={"approved": True}).status_code == 403
        assert client.put(url, json={"approved": True}, headers=ANONYMOUS).status_code == 401

    def test_not_found(self, client):
        url = f"/admin/places/{ObjectId()}/approval"
        assert client.put(url, json={"approved": True}, headers=ADMIN).status_code == 404
        assert client.put("/admin/places/nope/approval", json={"approved": True}, headers=ADMIN).status_code == 404
