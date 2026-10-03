import pytest
from bson import ObjectId

from app.auth import MOCK_USER_ID
from tests.helpers import as_user


def comment(client, place_id, text="Super miejsce", user="anna"):
    return client.post(f"/places/{place_id}/comments", json={"text": text}, headers=as_user(user))


def comments(client, place_id, **params):
    return client.get(f"/places/{place_id}/comments", params=params).json()


def test_create(client, created_place):
    response = comment(client, created_place["id"], text="  Polecam!  ")
    assert response.status_code == 201, response.text
    body = response.json()
    assert ObjectId.is_valid(body["id"])
    assert body["text"] == "Polecam!"
    assert body["user_id"] == "anna"
    assert body["place_id"] == created_place["id"]


def test_default_mock_user(client, created_place):
    body = client.post(f"/places/{created_place['id']}/comments", json={"text": "Hej"}).json()
    assert body["user_id"] == MOCK_USER_ID


def test_list_newest_first(client, created_place):
    for text in ("pierwszy", "drugi", "trzeci"):
        comment(client, created_place["id"], text=text)
    assert [c["text"] for c in comments(client, created_place["id"])] == ["trzeci", "drugi", "pierwszy"]


def test_pagination(client, created_place):
    for i in range(5):
        comment(client, created_place["id"], text=f"c{i}")
    assert [c["text"] for c in comments(client, created_place["id"], limit=2)] == ["c4", "c3"]
    assert [c["text"] for c in comments(client, created_place["id"], limit=2, skip=2)] == ["c2", "c1"]


def test_comments_are_per_place(client, created_place, minimal_payload):
    other = client.post("/places", json=minimal_payload).json()
    comment(client, created_place["id"], text="tu")
    comment(client, other["id"], text="tam")
    assert [c["text"] for c in comments(client, created_place["id"])] == ["tu"]


@pytest.mark.parametrize("text", ["", "   ", "x" * 2001])
def test_invalid_text(client, created_place, text):
    assert comment(client, created_place["id"], text=text).status_code == 422


def test_invalid_list_params(client, created_place):
    url = f"/places/{created_place['id']}/comments"
    assert client.get(url, params={"limit": 0}).status_code == 422
    assert client.get(url, params={"limit": 101}).status_code == 422


@pytest.mark.parametrize("place_id", [str(ObjectId()), "not-an-id"])
def test_unknown_place(client, place_id):
    assert comment(client, place_id).status_code == 404
    assert client.get(f"/places/{place_id}/comments").status_code == 404


class TestDelete:
    def test_author_can_delete(self, client, created_place):
        c = comment(client, created_place["id"], user="anna").json()
        response = client.delete(f"/places/{created_place['id']}/comments/{c['id']}", headers=as_user("anna"))
        assert response.status_code == 204
        assert comments(client, created_place["id"]) == []

    def test_other_user_cannot_delete(self, client, created_place):
        c = comment(client, created_place["id"], user="anna").json()
        response = client.delete(f"/places/{created_place['id']}/comments/{c['id']}", headers=as_user("bartek"))
        assert response.status_code == 403
        assert len(comments(client, created_place["id"])) == 1

    @pytest.mark.parametrize("comment_id", [str(ObjectId()), "not-an-id"])
    def test_not_found(self, client, created_place, comment_id):
        response = client.delete(f"/places/{created_place['id']}/comments/{comment_id}")
        assert response.status_code == 404

    def test_comment_of_other_place(self, client, created_place, minimal_payload):
        other = client.post("/places", json=minimal_payload).json()
        c = comment(client, created_place["id"], user="anna").json()
        response = client.delete(f"/places/{other['id']}/comments/{c['id']}", headers=as_user("anna"))
        assert response.status_code == 404
