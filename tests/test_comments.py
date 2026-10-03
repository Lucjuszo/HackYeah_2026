import pytest
from bson import ObjectId

from tests.helpers import ANONYMOUS, DEFAULT_USER, as_admin, as_user


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
    assert body["user_name"] == "anna"
    assert body["place_id"] == created_place["id"]
    assert body["edited_at"] is None


def test_default_mock_user(client, created_place):
    body = client.post(f"/places/{created_place['id']}/comments", json={"text": "Hej"}).json()
    assert body["user_id"] == DEFAULT_USER


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

    def test_admin_can_delete(self, client, created_place):
        c = comment(client, created_place["id"], user="anna").json()
        response = client.delete(f"/places/{created_place['id']}/comments/{c['id']}", headers=as_admin())
        assert response.status_code == 204
        assert comments(client, created_place["id"]) == []

    def test_anonymous_cannot_delete(self, client, created_place):
        c = comment(client, created_place["id"], user="anna").json()
        response = client.delete(f"/places/{created_place['id']}/comments/{c['id']}", headers=ANONYMOUS)
        assert response.status_code == 401

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


def test_anonymous_cannot_comment(client, created_place):
    response = client.post(f"/places/{created_place['id']}/comments", json={"text": "x"}, headers=ANONYMOUS)
    assert response.status_code == 401
    assert comments(client, created_place["id"]) == []


def test_reading_is_public(client, created_place):
    comment(client, created_place["id"])
    assert client.get(f"/places/{created_place['id']}/comments", headers=ANONYMOUS).status_code == 200


def test_author_name_comes_from_token(client, created_place):
    headers = as_user("u-123", name="Anna Kowalska")
    body = client.post(f"/places/{created_place['id']}/comments", json={"text": "Hej"}, headers=headers).json()
    assert (body["user_id"], body["user_name"]) == ("u-123", "Anna Kowalska")


class TestEdit:
    def edit(self, client, place_id, comment_id, text, headers):
        return client.patch(f"/places/{place_id}/comments/{comment_id}", json={"text": text}, headers=headers)

    def test_author_can_edit(self, client, created_place):
        c = comment(client, created_place["id"], text="stary", user="anna").json()
        response = self.edit(client, created_place["id"], c["id"], "  nowy  ", as_user("anna"))
        assert response.status_code == 200, response.text
        body = response.json()
        assert body["text"] == "nowy"
        assert body["edited_by"] == "anna"
        assert body["edited_at"] is not None
        assert (body["user_id"], body["created_at"]) == (c["user_id"], c["created_at"])
        assert comments(client, created_place["id"])[0]["text"] == "nowy"

    def test_admin_can_edit(self, client, created_place):
        c = comment(client, created_place["id"], user="anna").json()
        body = self.edit(client, created_place["id"], c["id"], "moderacja", as_admin("mod")).json()
        assert body["text"] == "moderacja"
        assert body["user_id"] == "anna"  # still the author
        assert body["edited_by"] == "mod"

    def test_other_user_cannot_edit(self, client, created_place):
        c = comment(client, created_place["id"], text="oryginał", user="anna").json()
        response = self.edit(client, created_place["id"], c["id"], "hack", as_user("bartek"))
        assert response.status_code == 403
        assert comments(client, created_place["id"])[0]["text"] == "oryginał"

    def test_anonymous_cannot_edit(self, client, created_place):
        c = comment(client, created_place["id"], user="anna").json()
        assert self.edit(client, created_place["id"], c["id"], "hack", ANONYMOUS).status_code == 401

    @pytest.mark.parametrize("text", ["", "   ", "x" * 2001])
    def test_invalid_text(self, client, created_place, text):
        c = comment(client, created_place["id"], user="anna").json()
        assert self.edit(client, created_place["id"], c["id"], text, as_user("anna")).status_code == 422

    @pytest.mark.parametrize("comment_id", [str(ObjectId()), "not-an-id"])
    def test_not_found(self, client, created_place, comment_id):
        assert self.edit(client, created_place["id"], comment_id, "x", as_admin()).status_code == 404

    def test_comment_of_other_place(self, client, created_place, minimal_payload):
        other = client.post("/places", json=minimal_payload).json()
        c = comment(client, created_place["id"], user="anna").json()
        assert self.edit(client, other["id"], c["id"], "x", as_user("anna")).status_code == 404
