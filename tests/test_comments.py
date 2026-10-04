import asyncio

import pytest
from bson import ObjectId

from app.config import settings
from app.db import create_client
from app.repositories import comments as repo

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


class TestLikes:
    def like(self, client, place_id, comment_id, headers, method="PUT"):
        return client.request(method, f"/places/{place_id}/comments/{comment_id}/like", headers=headers)

    def test_new_comment_has_no_likes(self, client, created_place):
        body = comment(client, created_place["id"]).json()
        assert (body["likes"], body["liked_by"]) == (0, [])

    def test_like_and_unlike(self, client, created_place):
        c = comment(client, created_place["id"], user="anna").json()
        response = self.like(client, created_place["id"], c["id"], as_user("bartek"))
        assert response.status_code == 200, response.text
        assert (response.json()["likes"], response.json()["liked_by"]) == (1, ["bartek"])

        response = self.like(client, created_place["id"], c["id"], as_user("bartek"), method="DELETE")
        assert response.status_code == 200, response.text
        assert (response.json()["likes"], response.json()["liked_by"]) == (0, [])

    def test_one_like_per_user(self, client, created_place):
        c = comment(client, created_place["id"]).json()
        for _ in range(2):
            body = self.like(client, created_place["id"], c["id"], as_user("bartek")).json()
        assert body["likes"] == 1
        body = self.like(client, created_place["id"], c["id"], as_user("celina")).json()
        assert (body["likes"], body["liked_by"]) == (2, ["bartek", "celina"])

    def test_unlike_without_like_changes_nothing(self, client, created_place):
        c = comment(client, created_place["id"]).json()
        self.like(client, created_place["id"], c["id"], as_user("bartek"))
        body = self.like(client, created_place["id"], c["id"], as_user("celina"), method="DELETE").json()
        assert (body["likes"], body["liked_by"]) == (1, ["bartek"])

    def test_most_liked_first(self, client, created_place):
        place_id = created_place["id"]
        ids = {text: comment(client, place_id, text=text).json()["id"] for text in ("a", "b", "c", "d")}
        for user in ("u1", "u2"):
            self.like(client, place_id, ids["b"], as_user(user))
        self.like(client, place_id, ids["a"], as_user("u1"))
        # Same number of likes: newest first.
        assert [c["text"] for c in comments(client, place_id)] == ["b", "a", "d", "c"]
        assert [c["text"] for c in comments(client, place_id, limit=2, skip=1)] == ["a", "d"]

    def test_unliked_comment_ties_with_never_liked(self, client, created_place):
        place_id = created_place["id"]
        old = comment(client, place_id, text="stary").json()
        self.like(client, place_id, old["id"], as_user("bartek"))
        self.like(client, place_id, old["id"], as_user("bartek"), method="DELETE")
        comment(client, place_id, text="nowy")
        # Both have 0 likes: the newer one comes first.
        assert [c["text"] for c in comments(client, place_id)] == ["nowy", "stary"]

    def test_comments_from_before_likes_get_zero(self, client, db, created_place):
        place_id = created_place["id"]
        old = comment(client, place_id, text="sprzed łapek").json()
        db[repo.COLLECTION].update_one({"_id": ObjectId(old["id"])}, {"$unset": {"likes": "", "liked_by": ""}})

        async def migrate():  # what the app does at start (lifespan -> ensure_indexes)
            mongo = create_client()
            try:
                await repo.ensure_indexes(mongo[settings.mongo_db])
            finally:
                await mongo.close()

        asyncio.run(migrate())
        assert db[repo.COLLECTION].find_one({"_id": ObjectId(old["id"])})["likes"] == 0
        liked = comment(client, place_id, text="polubiony").json()
        self.like(client, place_id, liked["id"], as_user("bartek"))
        self.like(client, place_id, liked["id"], as_user("bartek"), method="DELETE")
        newest = comment(client, place_id, text="najnowszy").json()
        assert [c["text"] for c in comments(client, place_id)] == ["najnowszy", "polubiony", "sprzed łapek"]
        assert newest["likes"] == 0

    def test_anonymous_cannot_like(self, client, created_place):
        c = comment(client, created_place["id"]).json()
        assert self.like(client, created_place["id"], c["id"], ANONYMOUS).status_code == 401
        assert self.like(client, created_place["id"], c["id"], ANONYMOUS, method="DELETE").status_code == 401

    @pytest.mark.parametrize("comment_id", [str(ObjectId()), "not-an-id"])
    def test_not_found(self, client, created_place, comment_id):
        assert self.like(client, created_place["id"], comment_id, as_user("anna")).status_code == 404
        assert self.like(client, created_place["id"], comment_id, as_user("anna"), method="DELETE").status_code == 404

    def test_comment_of_other_place(self, client, created_place, minimal_payload):
        other = client.post("/places", json=minimal_payload).json()
        c = comment(client, created_place["id"]).json()
        assert self.like(client, other["id"], c["id"], as_user("anna")).status_code == 404
