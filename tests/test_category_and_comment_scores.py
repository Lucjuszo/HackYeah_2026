import pytest

from tests.helpers import as_user
from tests.test_places_api import RYNEK, add_place


class TestCategory:
    def test_stored_and_returned(self, client, minimal_payload):
        place = add_place(client, minimal_payload, "Czytelnia", RYNEK, category="library")
        assert place["category"] == "library"
        assert client.get(f"/places/{place['id']}").json()["category"] == "library"
        assert client.get("/places/summary").json()[0]["category"] == "library"

    def test_optional(self, client, minimal_payload):
        assert add_place(client, minimal_payload, "X", RYNEK)["category"] is None

    def test_invalid(self, client, minimal_payload):
        response = client.post("/places", json={**minimal_payload, "category": "bar"})
        assert response.status_code == 422

    def test_update_and_clear(self, client, minimal_payload):
        place = add_place(client, minimal_payload, "X", RYNEK, category="cafe")
        url = f"/places/{place['id']}"
        assert client.patch(url, json={"category": "coworking"}).json()["category"] == "coworking"
        assert client.patch(url, json={"category": None}).json()["category"] is None

    def test_filter(self, client, minimal_payload):
        add_place(client, minimal_payload, "Kawa", RYNEK, category="cafe")
        add_place(client, minimal_payload, "Książki", RYNEK, category="library")
        names = [p["name"] for p in client.get("/places/summary", params={"category": "library"}).json()]
        assert names == ["Książki"]


class TestCommentScores:
    @pytest.fixture
    def place_url(self, client, created_place):
        return f"/places/{created_place['id']}"

    def test_list_shows_authors_rating(self, client, place_url):
        client.put(f"{place_url}/ratings/me", json={"score": 4}, headers=as_user("anna"))
        client.post(f"{place_url}/comments", json={"text": "Fajnie"}, headers=as_user("anna"))
        client.post(f"{place_url}/comments", json={"text": "Bez oceny"}, headers=as_user("bartek"))
        comments = {c["text"]: c["user_score"] for c in client.get(f"{place_url}/comments").json()}
        assert comments == {"Fajnie": 4, "Bez oceny": None}

    def test_follows_rating_changes(self, client, place_url):
        client.post(f"{place_url}/comments", json={"text": "A"}, headers=as_user("anna"))
        client.put(f"{place_url}/ratings/me", json={"score": 2}, headers=as_user("anna"))
        assert client.get(f"{place_url}/comments").json()[0]["user_score"] == 2
        client.delete(f"{place_url}/ratings/me", headers=as_user("anna"))
        assert client.get(f"{place_url}/comments").json()[0]["user_score"] is None

    def test_create_and_edit_include_score(self, client, place_url):
        client.put(f"{place_url}/ratings/me", json={"score": 5}, headers=as_user("anna"))
        comment = client.post(f"{place_url}/comments", json={"text": "A"}, headers=as_user("anna")).json()
        assert comment["user_score"] == 5
        edited = client.patch(f"{place_url}/comments/{comment['id']}", json={"text": "B"}, headers=as_user("anna")).json()
        assert edited["user_score"] == 5

    def test_rating_of_another_place_ignored(self, client, place_url, minimal_payload):
        other = add_place(client, minimal_payload, "Inne", RYNEK)
        client.put(f"/places/{other['id']}/ratings/me", json={"score": 1}, headers=as_user("anna"))
        client.post(f"{place_url}/comments", json={"text": "A"}, headers=as_user("anna"))
        assert client.get(f"{place_url}/comments").json()[0]["user_score"] is None
