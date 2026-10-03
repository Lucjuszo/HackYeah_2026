from pathlib import Path

import pytest
from bson import ObjectId

from app.config import settings
from app.repositories import places as repo
from tests.helpers import MEDIA_DIR, make_image


def upload(client, place_id, data=None, filename="photo.jpg"):
    data = make_image() if data is None else data
    return client.post(f"/places/{place_id}/photos", files={"file": (filename, data, "image/jpeg")})


def stored_files() -> list[Path]:
    return [p for p in MEDIA_DIR.rglob("*") if p.is_file()]


class TestUpload:
    def test_upload(self, client, created_place, db):
        response = upload(client, created_place["id"])
        assert response.status_code == 201, response.text
        photo = response.json()
        assert photo["content_type"] == "image/webp"
        assert (photo["width"], photo["height"]) == (64, 32)
        assert photo["url"] == f"/media/places/{created_place['id']}/{photo['id']}.webp"

        doc = db.places.find_one({"_id": ObjectId(created_place["id"])})
        assert doc["photos"][0]["key"] == f"places/{created_place['id']}/{photo['id']}.webp"
        assert len(stored_files()) == 1

    def test_photo_is_served(self, client, created_place):
        photo = upload(client, created_place["id"]).json()
        response = client.get(photo["url"])
        assert response.status_code == 200
        assert response.headers["content-type"] == "image/webp"
        assert len(response.content) == photo["size"]

    def test_photos_listed_on_place(self, client, created_place):
        ids = [upload(client, created_place["id"]).json()["id"] for _ in range(3)]
        place = client.get(f"/places/{created_place['id']}").json()
        assert [p["id"] for p in place["photos"]] == ids

    def test_not_an_image(self, client, created_place):
        response = upload(client, created_place["id"], data=b"definitely not a jpeg")
        assert response.status_code == 415
        assert stored_files() == []

    def test_too_large(self, client, created_place, monkeypatch):
        monkeypatch.setattr(settings, "max_photo_bytes", 100)
        response = upload(client, created_place["id"], data=make_image(size=(500, 500)))
        assert response.status_code == 413
        assert stored_files() == []

    def test_limit_per_place(self, client, created_place, monkeypatch):
        monkeypatch.setattr(settings, "max_photos_per_place", 2)
        assert upload(client, created_place["id"]).status_code == 201
        assert upload(client, created_place["id"]).status_code == 201
        response = upload(client, created_place["id"])
        assert response.status_code == 409
        assert len(stored_files()) == 2  # rejected upload cleaned up its file

    def test_db_failure_removes_stored_file(self, client, created_place, monkeypatch):
        async def broken_add_photo(*args, **kwargs):
            raise RuntimeError("db down")

        monkeypatch.setattr(repo, "add_photo", broken_add_photo)
        with pytest.raises(RuntimeError):
            upload(client, created_place["id"])
        assert stored_files() == []

    def test_unknown_place(self, client):
        assert upload(client, str(ObjectId())).status_code == 404
        assert stored_files() == []

    def test_invalid_place_id(self, client):
        assert upload(client, "not-an-id").status_code == 404
        assert stored_files() == []

    def test_missing_file(self, client, created_place):
        assert client.post(f"/places/{created_place['id']}/photos").status_code == 422


class TestDelete:
    def test_delete(self, client, created_place, db):
        keep = upload(client, created_place["id"]).json()
        remove = upload(client, created_place["id"]).json()

        response = client.delete(f"/places/{created_place['id']}/photos/{remove['id']}")
        assert response.status_code == 204

        place = client.get(f"/places/{created_place['id']}").json()
        assert [p["id"] for p in place["photos"]] == [keep["id"]]
        assert client.get(remove["url"]).status_code == 404
        assert client.get(keep["url"]).status_code == 200

    def test_delete_twice(self, client, created_place):
        photo = upload(client, created_place["id"]).json()
        url = f"/places/{created_place['id']}/photos/{photo['id']}"
        assert client.delete(url).status_code == 204
        assert client.delete(url).status_code == 404

    def test_photo_of_other_place(self, client, created_place, minimal_payload):
        other = client.post("/places", json=minimal_payload).json()
        photo = upload(client, created_place["id"]).json()
        assert client.delete(f"/places/{other['id']}/photos/{photo['id']}").status_code == 404
        assert client.get(photo["url"]).status_code == 200

    def test_invalid_place_id(self, client):
        assert client.delete("/places/not-an-id/photos/abc").status_code == 404
