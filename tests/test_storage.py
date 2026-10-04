import asyncio

import cloudinary.uploader
import pytest
from pydantic import SecretStr

from app.config import Settings, settings
from app.storage import CloudinaryStorage, LocalStorage, get_storage
from tests.helpers import make_image

CLOUDINARY_URL = "cloudinary://123456:s3cr%40t@demo-cloud"


@pytest.fixture
def uploads(monkeypatch):
    """Records Cloudinary SDK calls instead of talking to the API."""
    calls: list[tuple[str, dict]] = []

    def upload(file, **options):
        calls.append(("upload", {"data": file.read(), **options}))
        return {"public_id": options["public_id"]}

    def destroy(public_id, **options):
        calls.append(("destroy", {"public_id": public_id, **options}))
        return {"result": "ok"}

    monkeypatch.setattr(cloudinary.uploader, "upload", upload)
    monkeypatch.setattr(cloudinary.uploader, "destroy", destroy)
    return calls


@pytest.fixture
def cloudinary_storage(monkeypatch, uploads):
    monkeypatch.setattr(settings, "cloudinary_url", SecretStr(CLOUDINARY_URL))
    get_storage.cache_clear()
    yield get_storage()
    get_storage.cache_clear()


class TestCredentials:
    def test_from_url(self):
        assert Settings(_env_file=None, cloudinary_url=CLOUDINARY_URL).cloudinary_credentials() == (
            "demo-cloud", "123456", "s3cr@t"
        )

    def test_from_separate_variables(self):
        s = Settings(
            _env_file=None, cloudinary_cloud_name="c", cloudinary_api_key="k", cloudinary_api_secret="x"
        )
        assert s.cloudinary_credentials() == ("c", "k", "x")

    def test_not_configured(self):
        assert Settings(_env_file=None).cloudinary_credentials() is None

    def test_incomplete_variables(self):
        with pytest.raises(ValueError, match="CLOUDINARY_CLOUD_NAME"):
            Settings(_env_file=None, cloudinary_api_key="k", cloudinary_api_secret="x").cloudinary_credentials()

    def test_malformed_url(self):
        with pytest.raises(ValueError, match="CLOUDINARY_URL"):
            Settings(_env_file=None, cloudinary_url="https://example.com").cloudinary_credentials()


class TestBackendSelection:
    def test_local_without_credentials(self):
        assert isinstance(get_storage(), LocalStorage)

    def test_cloudinary_with_credentials(self, cloudinary_storage):
        assert isinstance(cloudinary_storage, CloudinaryStorage)

    def test_local_forced(self, monkeypatch):
        monkeypatch.setattr(settings, "cloudinary_url", SecretStr(CLOUDINARY_URL))
        monkeypatch.setattr(settings, "storage_backend", "local")
        get_storage.cache_clear()
        try:
            assert isinstance(get_storage(), LocalStorage)
        finally:
            get_storage.cache_clear()

    def test_cloudinary_required_but_missing(self, monkeypatch):
        monkeypatch.setattr(settings, "storage_backend", "cloudinary")
        get_storage.cache_clear()
        try:
            with pytest.raises(RuntimeError, match="CLOUDINARY_URL"):
                get_storage()
        finally:
            get_storage.cache_clear()


class TestCloudinaryStorage:
    storage = CloudinaryStorage("demo", "k", "x", folder="focusmap/")

    def test_public_id_drops_extension_and_adds_folder(self):
        assert self.storage.public_id("places/abc/p1_thumb.webp") == "focusmap/places/abc/p1_thumb"
        assert CloudinaryStorage("demo", "k", "x").public_id("places/abc/p1.webp") == "places/abc/p1"

    def test_url(self):
        assert self.storage.url("places/abc/p1.webp") == (
            "https://res.cloudinary.com/demo/image/upload/focusmap/places/abc/p1.webp"
        )
        assert self.storage.redirect_url("places/abc/p1.webp", download=True) == (
            "https://res.cloudinary.com/demo/image/upload/fl_attachment/focusmap/places/abc/p1.webp"
        )

    def test_no_local_path(self):
        assert self.storage.path("places/abc/p1.webp") is None

    def test_save_and_delete(self, uploads):
        asyncio.run(self.storage.save("places/abc/p1.webp", b"img", "image/webp"))
        asyncio.run(self.storage.delete("places/abc/p1.webp"))
        (op1, upload), (op2, destroy) = uploads
        assert (op1, op2) == ("upload", "destroy")
        assert upload["data"] == b"img"
        assert upload["public_id"] == "focusmap/places/abc/p1"
        assert upload["asset_folder"] == "focusmap/places/abc"
        assert (upload["cloud_name"], upload["api_key"], upload["api_secret"]) == ("demo", "k", "x")
        assert destroy["public_id"] == "focusmap/places/abc/p1"
        assert destroy["invalidate"] is True


class TestPhotosApiWithCloudinary:
    def test_upload_serve_and_delete(self, client, created_place, cloudinary_storage, uploads):
        resp = client.post(
            f"/places/{created_place}/photos", files={"file": ("p.jpg", make_image(), "image/jpeg")}
        )
        assert resp.status_code == 201, resp.text
        photo = resp.json()
        base = f"https://res.cloudinary.com/demo-cloud/image/upload/focusmap/places/{created_place}/{photo['id']}"
        assert photo["url"] == f"{base}.webp"
        assert photo["thumbnail"]["url"] == f"{base}_thumb.webp"
        assert [op for op, _ in uploads] == ["upload", "upload"]
        assert uploads[0][1]["data"][:4] == b"RIFF"  # already converted to WebP by the API

        file = client.get(f"/places/{created_place}/photos/{photo['id']}/file", follow_redirects=False)
        assert file.status_code == 307
        assert file.headers["location"] == f"{base}.webp"

        assert client.delete(f"/places/{created_place}/photos/{photo['id']}").status_code == 204
        assert sorted(c["public_id"] for op, c in uploads if op == "destroy") == [
            f"focusmap/places/{created_place}/{photo['id']}",
            f"focusmap/places/{created_place}/{photo['id']}_thumb",
        ]
