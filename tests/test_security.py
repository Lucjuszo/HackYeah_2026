"""Security regressions: hidden places, request limits, input bounds, headers, rate limits, image and geocoding abuse."""

import asyncio
import os
from io import BytesIO

import httpx
import pytest
from PIL import Image

from app import geocoding
from app.config import settings
from app.images import InvalidImage, process_photo
from app.middleware import BodySizeLimitMiddleware
from tests.helpers import ANONYMOUS, as_admin, as_user, make_image

AUTHOR = {}  # the client's default user (tests.helpers.DEFAULT_USER) creates the pending place
STRANGER = as_user("someone-else")
ADMIN = as_admin()


def upload(client, place_id, data=None, headers=None):
    data = make_image() if data is None else data
    return client.post(f"/places/{place_id}/photos", files={"file": ("photo.jpg", data, "image/jpeg")}, headers=headers)


class TestPendingPlaceIsHidden:
    """A place waiting for approval must not leak through its sub-resources, nor be writable by others."""

    @pytest.fixture(autouse=True)
    def _require_approval(self, monkeypatch):
        monkeypatch.setattr(settings, "places_require_approval", True)

    @pytest.fixture
    def pending(self, client, minimal_payload) -> str:
        response = client.post("/places", json=minimal_payload)
        assert response.status_code == 201, response.text
        assert response.json()["approved"] is False
        return response.json()["id"]

    @pytest.fixture
    def pending_with_content(self, client, pending) -> dict:
        photo = upload(client, pending)
        assert photo.status_code == 201, photo.text
        comment = client.post(f"/places/{pending}/comments", json={"text": "Jeszcze nikt nie widzi"})
        assert comment.status_code == 201, comment.text
        assert client.put(f"/places/{pending}/ratings/me", json={"score": 4}).status_code == 200
        return {"id": pending, "photo": photo.json()["id"], "comment": comment.json()["id"]}

    def reads(self, place: dict) -> list[str]:
        base = f"/places/{place['id']}"
        return [
            base,
            f"{base}/comments",
            f"{base}/ratings",
            f"{base}/photos",
            f"{base}/photos/{place['photo']}",
            f"{base}/photos/{place['photo']}/file",
        ]

    @pytest.mark.parametrize("headers", [STRANGER, ANONYMOUS], ids=["other-user", "anonymous"])
    def test_reads_are_404_for_others(self, client, pending_with_content, headers):
        for url in self.reads(pending_with_content):
            assert client.get(url, headers=headers).status_code == 404, url

    @pytest.mark.parametrize("headers", [AUTHOR, ADMIN], ids=["author", "admin"])
    def test_reads_work_for_author_and_admin(self, client, pending_with_content, headers):
        for url in self.reads(pending_with_content):
            assert client.get(url, headers=headers).status_code == 200, url

    def test_others_cannot_write(self, client, pending_with_content):
        base = f"/places/{pending_with_content['id']}"
        comment = f"{base}/comments/{pending_with_content['comment']}"
        attempts = [
            client.patch(base, json={"name": "Przejęte"}, headers=STRANGER),
            client.post(f"{base}/comments", json={"text": "spam"}, headers=STRANGER),
            client.put(f"{comment}/like", headers=STRANGER),
            client.put(f"{base}/ratings/me", json={"score": 1}, headers=STRANGER),
            upload(client, pending_with_content["id"], headers=STRANGER),
            client.delete(f"{base}/photos/{pending_with_content['photo']}", headers=STRANGER),
        ]
        assert [r.status_code for r in attempts] == [404] * len(attempts)
        assert client.get(base).json()["name"] != "Przejęte"

    def test_invalid_token_counts_as_anonymous(self, client, pending):
        assert client.get(f"/places/{pending}", headers={"Authorization": "Bearer not-a-jwt"}).status_code == 404

    def test_author_and_admin_can_edit(self, client, pending):
        assert client.patch(f"/places/{pending}", json={"name": "Autor"}).status_code == 200
        assert client.patch(f"/places/{pending}", json={"name": "Admin"}, headers=ADMIN).status_code == 200

    def test_public_after_approval(self, client, pending_with_content):
        place_id = pending_with_content["id"]
        assert client.put(f"/admin/places/{place_id}/approval", json={"approved": True}, headers=ADMIN).status_code == 200
        for url in self.reads(pending_with_content):
            assert client.get(url, headers=ANONYMOUS).status_code == 200, url
        assert client.post(f"/places/{place_id}/comments", json={"text": "ok"}, headers=STRANGER).status_code == 201


class TestRequestBodyLimit:
    def test_large_json_is_refused(self, client):
        body = b'{"name": "' + b"x" * settings.max_request_bytes + b'"}'
        response = client.post("/places", content=body, headers={"Content-Type": "application/json"})
        assert response.status_code == 413

    def test_refused_before_authentication(self, client):
        body = b"x" * (settings.max_request_bytes + 1)
        response = client.post("/places", content=body, headers={**ANONYMOUS, "Content-Type": "application/json"})
        assert response.status_code == 413

    def test_chunked_body_without_content_length_is_counted(self, client):
        def chunks():
            for _ in range(settings.max_request_bytes // 65536 + 2):
                yield b"x" * 65536

        response = client.post("/places", content=chunks(), headers={"Content-Type": "application/json"})
        assert response.status_code == 413

    def test_photo_upload_over_max_photo_bytes_is_refused(self, client, created_place):
        response = upload(client, created_place["id"], data=b"x" * (settings.max_photo_bytes + 100_000))
        assert response.status_code == 413

    def test_photo_upload_may_exceed_the_json_limit(self, client, created_place):
        # Noise doesn't compress: a PNG well above MAX_REQUEST_BYTES but under MAX_PHOTO_BYTES.
        raw = BytesIO()
        Image.frombytes("RGB", (800, 600), os.urandom(800 * 600 * 3)).save(raw, "PNG")
        assert settings.max_request_bytes < len(raw.getvalue()) < settings.max_photo_bytes
        assert upload(client, created_place["id"], data=raw.getvalue()).status_code == 201

    def test_invalid_content_length(self):
        sent = []

        async def app(scope, receive, send):  # never reached
            raise AssertionError

        async def receive():
            return {"type": "http.request", "body": b"", "more_body": False}

        async def send(message):
            sent.append(message)

        scope = {"type": "http", "method": "POST", "path": "/places", "headers": [(b"content-length", b"abc")]}
        asyncio.run(BodySizeLimitMiddleware(app)(scope, receive, send))
        assert sent[0]["status"] == 400

    def test_normal_requests_pass(self, client, minimal_payload):
        assert client.post("/places", json=minimal_payload).status_code == 201


class TestSecurityHeaders:
    def test_api_responses(self, client):
        headers = client.get("/places/summary").headers
        assert headers["X-Content-Type-Options"] == "nosniff"
        assert headers["X-Frame-Options"] == "DENY"
        assert headers["Referrer-Policy"] == "no-referrer"
        assert headers["Content-Security-Policy"] == "default-src 'none'; frame-ancestors 'none'"
        assert "Strict-Transport-Security" not in headers  # plain HTTP here

    def test_errors_get_them_too(self, client):
        response = client.get("/places/000000000000000000000000")
        assert response.status_code == 404
        assert response.headers["X-Content-Type-Options"] == "nosniff"

    def test_privacy_page_may_use_its_inline_style(self, client):
        assert "style-src 'unsafe-inline'" in client.get("/privacy").headers["Content-Security-Policy"]

    def test_docs_keep_working(self, client):
        response = client.get("/docs")
        assert response.status_code == 200
        assert "Content-Security-Policy" not in response.headers

    def test_hsts_over_https(self, client):
        assert "max-age" in client.get("https://testserver/health").headers["Strict-Transport-Security"]


class TestRateLimits:
    def test_new_places(self, client, minimal_payload, monkeypatch):
        monkeypatch.setattr(settings, "places_per_hour", 2)
        assert [client.post("/places", json=minimal_payload).status_code for _ in range(3)] == [201, 201, 429]
        # Per user: someone else can still add.
        assert client.post("/places", json=minimal_payload, headers=STRANGER).status_code == 201

    def test_place_edits(self, client, created_place, monkeypatch):
        monkeypatch.setattr(settings, "place_edits_per_hour", 1)
        url = f"/places/{created_place['id']}"
        first, second = (client.patch(url, json={"name": f"Nazwa {i}"}) for i in range(2))
        assert (first.status_code, second.status_code) == (200, 429)
        assert "Retry-After" in second.headers

    def test_admins_are_not_limited(self, client, minimal_payload, monkeypatch):
        for name in ("places_per_hour", "place_edits_per_hour", "comments_per_hour", "photo_uploads_per_hour"):
            monkeypatch.setattr(settings, name, 1)
        for _ in range(3):
            place = client.post("/places", json=minimal_payload, headers=ADMIN)
            assert place.status_code == 201
            url = f"/places/{place.json()['id']}"
            assert client.patch(url, json={"name": "a"}, headers=ADMIN).status_code == 200
            assert client.patch(url, json={"name": "b"}, headers=ADMIN).status_code == 200
            assert client.post(f"{url}/comments", json={"text": "x"}, headers=ADMIN).status_code == 201
            assert client.post(f"{url}/comments", json={"text": "y"}, headers=ADMIN).status_code == 201
            assert upload(client, place.json()["id"], headers=ADMIN).status_code == 201
            assert upload(client, place.json()["id"], headers=ADMIN).status_code == 201
        # The same limits still apply to a regular user.
        assert client.post("/places", json=minimal_payload).status_code == 201
        assert client.post("/places", json=minimal_payload).status_code == 429

    def test_edit_of_missing_place_does_not_count(self, client, monkeypatch):
        monkeypatch.setattr(settings, "place_edits_per_hour", 1)
        for _ in range(3):
            assert client.patch("/places/000000000000000000000000", json={"name": "x"}).status_code == 404


class TestInputBounds:
    """Numbers beyond BSON's int64 used to crash the DB driver (500); oversized inputs are refused (422)."""

    @pytest.mark.parametrize(
        "params", [{"min_price": 10**20}, {"max_price": 10**20}, {"skip": 10**20}], ids=["min", "max", "skip"]
    )
    def test_huge_query_numbers(self, client, params):
        assert client.get("/places/summary", params=params).status_code == 422

    def test_huge_comment_skip(self, client, created_place):
        assert client.get(f"/places/{created_place['id']}/comments", params={"skip": 10**20}).status_code == 422

    def test_huge_admin_skip(self, client):
        assert client.get("/admin/places", params={"skip": 10**20}, headers=ADMIN).status_code == 422

    @pytest.mark.parametrize(
        "extra",
        [
            {"osm": {"type": "node", "id": 10**20}},
            {"menu": [{"name": "Kawa", "price": 10**20}]},
            {"name": "x" * 301},
            {"address": {"city": "x" * 301, "country_code": "pl"}},
            {"menu": [{"name": "Kawa", "price": 100}] * 201},
            {"menu": [{"name": "Kawa", "price": 100, "description": "x" * 1001}]},
            {"opening_hours": {"periods": [{"day": 0, "open": "08:00", "close": "09:00"}] * 101}},
        ],
        ids=["osm-id", "menu-price", "name", "city", "menu-items", "menu-description", "periods"],
    )
    def test_oversized_place_fields(self, client, minimal_payload, extra):
        assert client.post("/places", json={**minimal_payload, **extra}).status_code == 422

    def test_huge_usage_price_is_kept_as_text(self, client, minimal_payload):
        response = client.post("/places", json={**minimal_payload, "usage_price": "9" * 30})
        assert response.status_code == 201, response.text
        assert response.json()["price_range"] is None

    def test_limits_leave_room_for_real_data(self, client, minimal_payload):
        place = {
            **minimal_payload,
            "name": "x" * 255,  # OSM's tag length limit
            "menu": [{"name": "Kawa", "price": 1500, "description": "d" * 1000}] * 200,
        }
        assert client.post("/places", json=place).status_code == 201


class TestImageBombs:
    def test_huge_non_jpeg_is_refused(self, monkeypatch):
        monkeypatch.setattr(Image, "MAX_IMAGE_PIXELS", 1000)
        with pytest.raises(InvalidImage):
            process_photo(make_image("PNG", size=(40, 40)), full_dimension=1600, thumbnail_dimension=400)

    def test_large_jpeg_is_decoded_at_reduced_scale(self, monkeypatch):
        # Over MAX_IMAGE_PIXELS (but under Pillow's hard limit of twice that): fine for JPEG thanks to draft mode.
        monkeypatch.setattr(Image, "MAX_IMAGE_PIXELS", 3000 * 2000 // 1.5)
        result = process_photo(make_image(size=(3000, 2000)), full_dimension=1000, thumbnail_dimension=200)
        assert (result.full.width, result.full.height) == (1000, 667)

    def test_over_hard_limit_is_refused(self, monkeypatch):
        monkeypatch.setattr(Image, "MAX_IMAGE_PIXELS", 100)
        with pytest.raises(InvalidImage):
            process_photo(make_image(size=(100, 100)), full_dimension=1600, thumbnail_dimension=400)

    def test_truncated_png_is_invalid_not_a_crash(self):
        raw = make_image("PNG", size=(200, 200), color=(1, 2, 3))
        with pytest.raises(InvalidImage):
            process_photo(raw[: len(raw) // 2], full_dimension=1600, thumbnail_dimension=400)


class TestGeocodingAbuse:
    def test_waiting_queue_is_bounded(self, monkeypatch):
        monkeypatch.setattr(geocoding, "MAX_WAITING", 2)
        monkeypatch.setattr(geocoding, "MIN_INTERVAL_S", 0.0)
        release = asyncio.Event()

        async def slow(request: httpx.Request) -> httpx.Response:
            await release.wait()
            return httpx.Response(200, json=[])

        async def scenario():
            geocoder = geocoding.Geocoder(transport=httpx.MockTransport(slow))
            first = asyncio.create_task(geocoder.search("a"))  # holds the lock
            waiting = [asyncio.create_task(geocoder.search(q)) for q in ("b", "c")]
            await asyncio.sleep(0.05)
            with pytest.raises(geocoding.GeocodingUnavailable):
                await geocoder.search("d")  # queue full: refused at once
            release.set()
            assert await asyncio.gather(first, *waiting) == [[], [], []]
            assert await geocoder.search("e") == []  # queue drained, accepted again
            await geocoder.aclose()

        asyncio.run(scenario())

    @pytest.mark.parametrize("body", [b"<html>not json</html>", b'[{"unexpected": 1}]', b'"a string"'])
    def test_malformed_upstream_answer_is_503(self, client, monkeypatch, body):
        from app.routers import geocode as geocode_router

        monkeypatch.setattr(geocoding, "MIN_INTERVAL_S", 0.0)
        transport = httpx.MockTransport(lambda request: httpx.Response(200, content=body))
        monkeypatch.setattr(geocode_router, "geocoder", geocoding.Geocoder(transport=transport))
        assert client.get("/geocode", params={"q": "Kraków"}).status_code == 503
