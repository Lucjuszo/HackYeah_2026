"""Things the browser frontend depends on: CORS, absolute photo URLs, health, rate limits, typed auth info."""

import pytest
from pymongo.errors import ServerSelectionTimeoutError

import app.main
from app.config import Settings, settings
from tests.helpers import ANONYMOUS, as_user, make_image

FRONTEND = "http://localhost:5173"


def upload(client, place_id, headers=None):
    return client.post(
        f"/places/{place_id}/photos", files={"file": ("p.jpg", make_image(), "image/jpeg")}, headers=headers
    )


class TestCors:
    def test_preflight_from_frontend(self, client):
        response = client.options(
            "/places",
            headers={
                "Origin": FRONTEND,
                "Access-Control-Request-Method": "POST",
                "Access-Control-Request-Headers": "authorization,content-type",
            },
        )
        assert response.status_code == 200
        assert response.headers["access-control-allow-origin"] == FRONTEND
        assert "authorization" in response.headers["access-control-allow-headers"].lower()

    def test_simple_request_exposes_total_count(self, client):
        response = client.get("/places", headers={"Origin": FRONTEND})
        assert response.headers["access-control-allow-origin"] == FRONTEND
        assert "X-Total-Count" in response.headers["access-control-expose-headers"]

    def test_unknown_origin_not_allowed(self, client):
        response = client.get("/places", headers={"Origin": "https://evil.example"})
        assert "access-control-allow-origin" not in response.headers

    @pytest.mark.parametrize(
        "origin", ["http://localhost:61234", "http://127.0.0.1:8080", "http://localhost", "https://localhost:443"]
    )
    def test_any_localhost_port_allowed(self, client, origin):
        # `flutter run -d chrome` serves the app on a random port.
        response = client.options(
            "/places", headers={"Origin": origin, "Access-Control-Request-Method": "GET"}
        )
        assert response.status_code == 200
        assert response.headers["access-control-allow-origin"] == origin

    @pytest.mark.parametrize(
        "origin", ["http://localhost.evil.com", "http://evil.com/localhost", "http://192.168.0.5:3000"]
    )
    def test_lookalike_origins_rejected(self, client, origin):
        response = client.get("/places", headers={"Origin": origin})
        assert "access-control-allow-origin" not in response.headers

    def test_localhost_regex_can_be_disabled(self):
        assert Settings(_env_file=None, cors_allow_localhost=False).cors_origin_regex() is None

    def test_origins_parsing(self):
        config = Settings(_env_file=None, cors_origins=" http://a.test/ , http://b.test,, ")
        assert config.cors_origin_list() == ["http://a.test", "http://b.test"]


class TestPhotoUrls:
    def test_relative_by_default(self, client, created_place):
        photo = upload(client, created_place["id"]).json()
        assert photo["url"].startswith("/media/places/")

    def test_absolute_with_public_base_url(self, client, created_place, monkeypatch):
        monkeypatch.setattr(settings, "public_base_url", "https://api.example.com/")
        photo = upload(client, created_place["id"]).json()
        assert photo["url"] == f"https://api.example.com/media/places/{created_place['id']}/{photo['id']}.webp"
        assert photo["thumbnail"]["url"].startswith("https://api.example.com/media/")
        summary = client.get("/places/summary").json()[0]
        assert summary["thumbnail_url"] == photo["thumbnail"]["url"]

    def test_uploader_name(self, client, created_place):
        photo = upload(client, created_place["id"], headers=as_user("anna", name="Anna K.")).json()
        assert photo["uploaded_by_name"] == "Anna K."
        assert client.get(f"/places/{created_place['id']}").json()["photos"][0]["uploaded_by_name"] == "Anna K."


class TestHealth:
    def test_ok(self, client):
        response = client.get("/health")
        assert response.status_code == 200
        assert response.json() == {"status": "ok", "mongo": "ok"}

    def test_database_down_is_503(self, client, monkeypatch):
        class DownDb:
            async def command(self, *args, **kwargs):
                raise ServerSelectionTimeoutError("no servers")

        monkeypatch.setattr(app.main, "get_db", lambda: DownDb())
        response = client.get("/health")
        assert response.status_code == 503
        assert response.json() == {"status": "degraded", "mongo": "unreachable"}


class TestRateLimits:
    def test_photo_uploads(self, client, created_place, monkeypatch):
        monkeypatch.setattr(settings, "photo_uploads_per_hour", 2)
        assert upload(client, created_place["id"]).status_code == 201
        assert upload(client, created_place["id"]).status_code == 201
        response = upload(client, created_place["id"])
        assert response.status_code == 429
        assert 0 < int(response.headers["Retry-After"]) <= 3600
        # Per user: someone else can still upload.
        assert upload(client, created_place["id"], headers=as_user("bartek")).status_code == 201

    def test_comments(self, client, created_place, monkeypatch):
        monkeypatch.setattr(settings, "comments_per_hour", 1)
        url = f"/places/{created_place['id']}/comments"
        assert client.post(url, json={"text": "one", "score": 4}).status_code == 201
        assert client.post(url, json={"text": "two", "score": 4}).status_code == 429

    def test_zero_disables(self, client, created_place, monkeypatch):
        monkeypatch.setattr(settings, "comments_per_hour", 0)
        url = f"/places/{created_place['id']}/comments"
        for i in range(5):
            assert client.post(url, json={"text": f"c{i}", "score": 4}).status_code == 201


def test_comments_total_count(client, created_place):
    url = f"/places/{created_place['id']}/comments"
    for i in range(3):
        client.post(url, json={"text": f"c{i}", "score": 4})
    response = client.get(url, params={"limit": 1})
    assert len(response.json()) == 1
    assert response.headers["X-Total-Count"] == "3"


def test_auth_providers_schema(client):
    body = client.get("/auth/providers", headers=ANONYMOUS).json()
    assert {p["name"] for p in body["providers"]} == {"github", "google"}
    assert all(p["login_url"].endswith("/login") for p in body["providers"])
    schema = client.get("/openapi.json").json()
    assert "AuthProviders" in schema["components"]["schemas"]
    assert "PlaceSummary" in schema["components"]["schemas"]


@pytest.mark.parametrize("path", ["/places", "/places/summary"])
def test_list_endpoints_documented_with_total_header(client, path):
    assert client.get(path).headers["X-Total-Count"] == "0"
