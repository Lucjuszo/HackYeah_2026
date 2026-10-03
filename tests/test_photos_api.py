from io import BytesIO
from pathlib import Path

import pytest
from bson import ObjectId
from PIL import Image

from app.config import settings
from app.repositories import places as repo
from tests.helpers import ANONYMOUS, DEFAULT_USER, MEDIA_DIR, as_admin, as_user, make_image


def upload(client, place_id, data=None, filename="photo.jpg", headers=None):
    data = make_image() if data is None else data
    return client.post(f"/places/{place_id}/photos", files={"file": (filename, data, "image/jpeg")}, headers=headers)


def stored_files() -> list[Path]:
    return [p for p in MEDIA_DIR.rglob("*") if p.is_file()]


def gradient_bitmap(size: tuple[int, int], fmt: str = "BMP") -> bytes:
    """A simulated photo: a colour gradient, so the encoder can't shrink it to almost nothing."""
    width, height = size
    img = Image.new("RGB", size)
    img.putdata([(x * 255 // width, y * 255 // height, (x + y) % 256) for y in range(height) for x in range(width)])
    buf = BytesIO()
    img.save(buf, fmt)
    return buf.getvalue()


def image_size(data: bytes) -> tuple[int, int]:
    img = Image.open(BytesIO(data))
    assert img.format == "WEBP"
    return img.size


class TestUpload:
    def test_upload(self, client, created_place, db):
        place_id = created_place["id"]
        response = upload(client, place_id)
        assert response.status_code == 201, response.text
        photo = response.json()
        assert photo["content_type"] == "image/webp"
        assert (photo["width"], photo["height"]) == (64, 32)
        assert photo["url"] == f"/media/places/{place_id}/{photo['id']}.webp"
        assert photo["thumbnail"]["url"] == f"/media/places/{place_id}/{photo['id']}_thumb.webp"
        assert (photo["thumbnail"]["width"], photo["thumbnail"]["height"]) == (64, 32)  # never upscaled

        doc = db.places.find_one({"_id": ObjectId(place_id)})
        assert doc["photos"][0]["key"] == f"places/{place_id}/{photo['id']}.webp"
        assert doc["photos"][0]["thumbnail"]["key"] == f"places/{place_id}/{photo['id']}_thumb.webp"
        assert sorted(p.name for p in stored_files()) == [f"{photo['id']}.webp", f"{photo['id']}_thumb.webp"]

    @pytest.mark.parametrize(
        ("size", "full", "thumbnail"),
        [
            ((2400, 900), (1600, 600), (400, 150)),  # landscape
            ((900, 1800), (800, 1600), (200, 400)),  # portrait
            ((1000, 1000), (1000, 1000), (400, 400)),  # only the thumbnail is downscaled
        ],
    )
    def test_creates_both_sizes(self, client, created_place, size, full, thumbnail):
        photo = upload(client, created_place["id"], data=gradient_bitmap(size), filename="photo.bmp").json()
        assert (photo["width"], photo["height"]) == full
        assert (photo["thumbnail"]["width"], photo["thumbnail"]["height"]) == thumbnail

        full_file = client.get(photo["url"])
        thumb_file = client.get(photo["thumbnail"]["url"])
        assert image_size(full_file.content) == full
        assert image_size(thumb_file.content) == thumbnail
        assert len(full_file.content) == photo["size"]
        assert len(thumb_file.content) == photo["thumbnail"]["size"]
        assert photo["thumbnail"]["size"] < photo["size"]

    @pytest.mark.parametrize("fmt", ["BMP", "PNG", "JPEG", "GIF", "WEBP"])
    def test_accepted_formats(self, client, created_place, fmt):
        response = upload(client, created_place["id"], data=gradient_bitmap((120, 80), fmt))
        assert response.status_code == 201, response.text
        assert response.json()["content_type"] == "image/webp"

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
        assert len(stored_files()) == 4  # 2 photos x 2 sizes; the rejected upload cleaned up its files

    def test_db_failure_removes_stored_files(self, client, created_place, monkeypatch):
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


def test_missing_media_file_is_404(client):
    assert client.get("/media/places/nothing/here.webp").status_code == 404


def test_media_path_traversal_is_404(client):
    assert client.get("/media/%2e%2e/%2e%2e/pytest.ini").status_code == 404
    assert client.get("/media/..%2F..%2Fpytest.ini").status_code == 404


class TestList:
    def test_list(self, client, created_place):
        ids = [upload(client, created_place["id"]).json()["id"] for _ in range(2)]
        response = client.get(f"/places/{created_place['id']}/photos", headers=ANONYMOUS)
        assert response.status_code == 200
        photos = response.json()
        assert [p["id"] for p in photos] == ids
        assert all(p["thumbnail"]["url"].endswith("_thumb.webp") for p in photos)

    def test_place_without_photos(self, client, created_place):
        assert client.get(f"/places/{created_place['id']}/photos").json() == []

    @pytest.mark.parametrize("place_id", [str(ObjectId()), "not-an-id"])
    def test_unknown_place(self, client, place_id):
        assert client.get(f"/places/{place_id}/photos").status_code == 404

    def test_get_one(self, client, created_place):
        photo = upload(client, created_place["id"]).json()
        response = client.get(f"/places/{created_place['id']}/photos/{photo['id']}", headers=ANONYMOUS)
        assert response.status_code == 200
        assert response.json() == photo

    def test_get_one_unknown(self, client, created_place):
        assert client.get(f"/places/{created_place['id']}/photos/nope").status_code == 404


class TestDownload:
    @staticmethod
    def file_url(place_id, photo_id):
        return f"/places/{place_id}/photos/{photo_id}/file"

    def test_full_by_default(self, client, created_place):
        photo = upload(client, created_place["id"], data=gradient_bitmap((2000, 1000))).json()
        response = client.get(self.file_url(created_place["id"], photo["id"]), headers=ANONYMOUS)
        assert response.status_code == 200
        assert response.headers["content-type"] == "image/webp"
        assert response.headers["content-disposition"].startswith("inline")
        assert image_size(response.content) == (1600, 800)
        assert len(response.content) == photo["size"]

    def test_thumbnail(self, client, created_place):
        photo = upload(client, created_place["id"], data=gradient_bitmap((2000, 1000))).json()
        response = client.get(self.file_url(created_place["id"], photo["id"]), params={"size": "thumbnail"})
        assert response.status_code == 200
        assert image_size(response.content) == (400, 200)
        assert len(response.content) == photo["thumbnail"]["size"]

    def test_as_attachment(self, client, created_place):
        photo = upload(client, created_place["id"]).json()
        response = client.get(self.file_url(created_place["id"], photo["id"]), params={"download": "true"})
        assert response.headers["content-disposition"] == f'attachment; filename="{photo["id"]}.webp"'

    def test_invalid_size(self, client, created_place):
        photo = upload(client, created_place["id"]).json()
        response = client.get(self.file_url(created_place["id"], photo["id"]), params={"size": "huge"})
        assert response.status_code == 422

    def test_photo_without_thumbnail_falls_back_to_full(self, client, created_place, db):
        photo = upload(client, created_place["id"]).json()
        db.places.update_one({"_id": ObjectId(created_place["id"])}, {"$unset": {"photos.0.thumbnail": ""}})
        response = client.get(self.file_url(created_place["id"], photo["id"]), params={"size": "thumbnail"})
        assert response.status_code == 200
        assert len(response.content) == photo["size"]

    def test_unknown_photo(self, client, created_place):
        assert client.get(self.file_url(created_place["id"], "nope")).status_code == 404
        assert client.get(self.file_url("not-an-id", "nope")).status_code == 404

    def test_missing_file_on_disk(self, client, created_place):
        photo = upload(client, created_place["id"]).json()
        for path in stored_files():
            path.unlink()
        assert client.get(self.file_url(created_place["id"], photo["id"])).status_code == 404


class TestDelete:
    def test_delete(self, client, created_place, db):
        keep = upload(client, created_place["id"]).json()
        remove = upload(client, created_place["id"]).json()

        response = client.delete(f"/places/{created_place['id']}/photos/{remove['id']}")
        assert response.status_code == 204

        place = client.get(f"/places/{created_place['id']}").json()
        assert [p["id"] for p in place["photos"]] == [keep["id"]]
        assert client.get(remove["url"]).status_code == 404
        assert client.get(remove["thumbnail"]["url"]).status_code == 404
        assert client.get(keep["url"]).status_code == 200
        assert len(stored_files()) == 2  # both sizes of the kept photo

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


class TestPermissions:
    def test_upload_records_uploader(self, client, created_place):
        photo = upload(client, created_place["id"], headers=as_user("anna")).json()
        assert photo["uploaded_by"] == "anna"
        place = client.get(f"/places/{created_place['id']}").json()
        assert place["photos"][0]["uploaded_by"] == "anna"

    def test_anonymous_cannot_upload(self, client, created_place):
        assert upload(client, created_place["id"], headers=ANONYMOUS).status_code == 401
        assert stored_files() == []

    def test_other_user_cannot_delete(self, client, created_place):
        photo = upload(client, created_place["id"], headers=as_user("anna")).json()
        url = f"/places/{created_place['id']}/photos/{photo['id']}"
        assert client.delete(url, headers=as_user("bartek")).status_code == 403
        assert client.get(photo["url"]).status_code == 200

    def test_admin_can_delete(self, client, created_place):
        photo = upload(client, created_place["id"], headers=as_user("anna")).json()
        assert client.delete(f"/places/{created_place['id']}/photos/{photo['id']}", headers=as_admin()).status_code == 204
        assert client.get(photo["url"]).status_code == 404

    def test_anonymous_cannot_delete(self, client, created_place):
        photo = upload(client, created_place["id"]).json()
        url = f"/places/{created_place['id']}/photos/{photo['id']}"
        assert client.delete(url, headers=ANONYMOUS).status_code == 401
        assert photo["uploaded_by"] == DEFAULT_USER
