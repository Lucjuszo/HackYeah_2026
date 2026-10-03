"""OAuth login that returns to a frontend page chosen by the frontend (`return_to`), e.g. Flutter web on a random port."""

from urllib.parse import parse_qs, urlparse

import pytest

from app.config import settings
from tests.helpers import ANONYMOUS
from tests.test_auth import bearer, callback, fake_provider  # noqa: F401 (fixture)


@pytest.fixture(autouse=True)
def fresh_session(client):
    # The client (and its session cookie) is shared by the whole test session.
    client.cookies.clear()
    yield
    client.cookies.clear()


def login(client, provider="google", **params):
    return client.get(f"/auth/{provider}/login", params=params, headers=ANONYMOUS, follow_redirects=False)


def fragment(response) -> dict[str, str]:
    assert response.status_code == 302, response.text
    return {k: v[0] for k, v in parse_qs(urlparse(response.headers["location"]).fragment).items()}


@pytest.mark.parametrize(
    "return_to",
    [
        "http://localhost:61234/auth_callback.html",  # flutter run -d chrome, random port
        "http://127.0.0.1:50000/callback",  # desktop app's loopback page
        "http://localhost:5173/",  # CORS_ORIGINS
    ],
)
def test_token_goes_back_to_the_frontend(client, fake_provider, return_to):  # noqa: F811
    assert login(client, return_to=return_to).status_code == 302
    response = callback(client, provider="google")
    location = response.headers["location"]
    assert location.startswith(return_to + "#")
    token = fragment(response)["access_token"]
    assert client.get("/auth/me", headers=bearer(token)).status_code == 200


def test_existing_fragment_is_replaced(client, fake_provider):  # noqa: F811
    login(client, return_to="http://localhost:5173/#/map")
    assert callback(client, provider="google").headers["location"].startswith("http://localhost:5173/#access_token=")


def test_return_to_wins_over_auth_redirect_url(client, fake_provider, monkeypatch):  # noqa: F811
    monkeypatch.setattr(settings, "auth_redirect_url", "http://localhost:3000/auth/done")
    login(client, return_to="http://localhost:5173/auth_callback.html")
    assert callback(client, provider="google").headers["location"].startswith("http://localhost:5173/auth_callback.html#")


def test_used_only_once(client, fake_provider):  # noqa: F811
    login(client, return_to="http://localhost:5173/")
    callback(client, provider="google")
    assert callback(client, provider="google").status_code == 200  # back to JSON


def test_login_without_return_to_clears_an_old_one(client, fake_provider):  # noqa: F811
    login(client, return_to="http://localhost:5173/")
    login(client)
    assert callback(client, provider="google").status_code == 200


@pytest.mark.parametrize(
    "return_to",
    [
        "https://evil.example/steal",
        "http://localhost.evil.example/",
        "javascript:alert(1)",
        "//localhost:5173/",
        "http://user:pass@localhost:5173/",
        "not a url",
    ],
)
def test_untrusted_return_to_rejected(client, return_to):
    response = login(client, return_to=return_to)
    assert response.status_code == 400
    assert "return_to" in response.json()["detail"]


def test_localhost_not_allowed_when_disabled(client, monkeypatch):
    monkeypatch.setattr(settings, "cors_allow_localhost", False)
    assert login(client, return_to="http://localhost:61234/").status_code == 400
    assert login(client, return_to="http://localhost:5173/").status_code == 302  # still in CORS_ORIGINS


def test_cancelled_login_returns_error_to_frontend(client):
    login(client, return_to="http://localhost:5173/")
    assert fragment(callback(client, provider="google", error="access_denied")) == {"error": "access_denied"}


def test_failed_login_returns_error_to_frontend(client, fake_provider):  # noqa: F811
    from authlib.integrations.base_client.errors import OAuthError

    fake_provider["identity"] = OAuthError(description="mismatching_state")
    login(client, return_to="http://localhost:5173/")
    assert fragment(callback(client, provider="google")) == {"error": "login_failed"}
