"""Google login, end to end: real authlib flow (state cookie, code exchange, userinfo) against a fake Google.

Nothing leaves the process: the Google client's HTTP transport is swapped for httpx.MockTransport,
so these tests also check what we send to Google, not only what we do with its answer.
"""

import json
from urllib.parse import parse_qs, urlparse

import httpx
import pytest

from app.auth import oauth as oauth_flow
from app.config import settings
from tests.helpers import ANONYMOUS
from tests.test_auth import bearer

TOKEN_URL = "https://oauth2.googleapis.com/token"
USERINFO_URL = "https://www.googleapis.com/oauth2/v3/userinfo"

PROFILE = {
    "sub": "109876543210987654321",
    "name": "Anna Kowalska",
    "email": "anna.kowalska@gmail.com",
    "email_verified": True,
    "picture": "https://lh3.googleusercontent.com/a/anna",
}


class FakeGoogle:
    """Answers the token and userinfo endpoints; records every request."""

    def __init__(self):
        self.profile = dict(PROFILE)
        self.token_status = 200
        self.userinfo_status = 200
        self.requests: list[httpx.Request] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        url = str(request.url).split("?", 1)[0]
        if request.method == "POST" and url == TOKEN_URL:
            if self.token_status != 200:
                return httpx.Response(self.token_status, json={"error": "invalid_grant"})
            return httpx.Response(
                200, json={"access_token": "google-access-token", "token_type": "Bearer", "expires_in": 3599}
            )
        if request.method == "GET" and url == USERINFO_URL:
            if self.userinfo_status != 200:
                return httpx.Response(self.userinfo_status, json={"error": "server_error"})
            return httpx.Response(200, json=self.profile)
        return httpx.Response(404)

    def token_request(self) -> dict[str, str]:
        request = next(r for r in self.requests if str(r.url) == TOKEN_URL)
        return {k: v[0] for k, v in parse_qs(request.content.decode()).items()}

    def userinfo_request(self) -> httpx.Request:
        return next(r for r in self.requests if str(r.url).startswith(USERINFO_URL))


@pytest.fixture
def google(monkeypatch):
    fake = FakeGoogle()
    client = oauth_flow.oauth.create_client("google")
    monkeypatch.setitem(client.client_kwargs, "transport", httpx.MockTransport(fake))
    return fake


@pytest.fixture(autouse=True)
def fresh_session(client):
    # The client (and its session cookie with the OAuth state) is shared by the whole test session.
    client.cookies.clear()
    yield
    client.cookies.clear()


def start_login(client, **params) -> dict[str, str]:
    """GET /auth/google/login; returns the query sent to Google's consent screen."""
    response = client.get("/auth/google/login", params=params, headers=ANONYMOUS, follow_redirects=False)
    assert response.status_code == 302, response.text
    return {k: v[0] for k, v in parse_qs(urlparse(response.headers["location"]).query).items()}


def google_redirects_back(client, state: str, **params):
    return client.get(
        "/auth/google/callback",
        params={"code": "google-auth-code", "state": state, **params},
        headers=ANONYMOUS,
        follow_redirects=False,
    )


def log_in(client) -> httpx.Response:
    return google_redirects_back(client, start_login(client)["state"])


class TestConsentScreenRequest:
    def test_asks_only_for_scopes_that_need_no_google_verification(self, client):
        # The whole point: anyone with a Google account can log in without Google reviewing the app.
        scopes = set(start_login(client)["scope"].split())
        assert scopes == {"email", "profile"}
        assert scopes <= oauth_flow.GOOGLE_NON_SENSITIVE_SCOPES

    def test_registered_scopes_are_non_sensitive(self):
        assert set(oauth_flow.GOOGLE_SCOPES) <= oauth_flow.GOOGLE_NON_SENSITIVE_SCOPES

    def test_request_parameters(self, client):
        query = start_login(client)
        assert query["response_type"] == "code"
        assert query["client_id"] == "test-google-client"
        assert query["redirect_uri"] == "http://testserver/auth/google/callback"
        assert query["prompt"] == "select_account"
        assert len(query["state"]) >= 20
        # No offline access / refresh token: we never call Google after the login.
        assert "access_type" not in query

    def test_every_login_gets_a_new_state(self, client):
        assert start_login(client)["state"] != start_login(client)["state"]

    def test_listed_as_provider(self, client):
        providers = client.get("/auth/providers", headers=ANONYMOUS).json()["providers"]
        google = next(p for p in providers if p["name"] == "google")
        assert google["login_url"] == "http://testserver/auth/google/login"

    def test_public_callback_url(self, client, monkeypatch):
        monkeypatch.setattr(settings, "oauth_callback_base_url", "https://api.thirdplaces.pl/")
        assert start_login(client)["redirect_uri"] == "https://api.thirdplaces.pl/auth/google/callback"


class TestCallback:
    def test_creates_user_from_google_profile(self, client, db, google):
        response = log_in(client)
        assert response.status_code == 200, response.text
        user = response.json()["user"]
        assert user["name"] == "Anna Kowalska"
        assert user["email"] == "anna.kowalska@gmail.com"
        assert user["avatar_url"] == "https://lh3.googleusercontent.com/a/anna"
        assert user["providers"] == ["google"]
        assert user["role"] == "user"

        stored = db.users.find_one({})
        assert stored["identities"] == [{"provider": "google", "subject": "109876543210987654321"}]

        token = response.json()["access_token"]
        assert client.get("/auth/me", headers=bearer(token)).json() == user

    def test_code_exchange_and_userinfo_requests(self, client, google):
        query = start_login(client)
        google_redirects_back(client, query["state"])

        exchange = google.token_request()
        assert exchange["grant_type"] == "authorization_code"
        assert exchange["code"] == "google-auth-code"
        # Must be identical to the redirect_uri of the consent request, or Google refuses the code.
        assert exchange["redirect_uri"] == query["redirect_uri"]

        userinfo = google.userinfo_request()
        assert userinfo.headers["authorization"] == "Bearer google-access-token"

    def test_token_allows_writes(self, client, google, minimal_payload):
        body = log_in(client).json()
        place = client.post("/places", json=minimal_payload, headers=bearer(body["access_token"]))
        assert place.status_code == 201
        assert place.json()["created_by"] == body["user"]["id"]

    def test_user_is_identified_by_sub_not_email(self, client, db, google):
        first = log_in(client).json()["user"]
        google.profile["email"] = "anna@nowa-domena.pl"  # address changed, same Google account
        second = log_in(client).json()["user"]
        assert second["id"] == first["id"]
        assert second["email"] == "anna@nowa-domena.pl"

        google.profile = {**PROFILE, "sub": "222"}  # another account reusing the address
        assert log_in(client).json()["user"]["id"] != first["id"]
        assert db.users.count_documents({}) == 2

    def test_google_and_github_accounts_stay_separate(self, client, db, google, monkeypatch):
        google_user = log_in(client).json()["user"]

        async def github_identity(provider, request):
            return oauth_flow.OAuthIdentity("github", PROFILE["sub"], "anna", PROFILE["email"], True, None)

        monkeypatch.setattr(oauth_flow, "fetch_identity", github_identity)
        github = client.get("/auth/github/callback", params={"code": "c", "state": "s"}, headers=ANONYMOUS)
        assert github.json()["user"]["id"] != google_user["id"]
        assert db.users.count_documents({}) == 2

    def test_admin_email(self, client, google):
        google.profile["email"] = "Boss@Example.com"
        assert log_in(client).json()["user"]["role"] == "admin"

    @pytest.mark.parametrize("verified", [False, "false", None])
    def test_unverified_email_is_not_trusted(self, client, google, verified):
        google.profile["email"] = "boss@example.com"
        if verified is None:
            del google.profile["email_verified"]
        else:
            google.profile["email_verified"] = verified
        user = log_in(client).json()["user"]
        assert user["role"] == "user"
        assert user["email"] is None

    def test_verified_as_string(self, client, google):
        google.profile["email_verified"] = "true"
        assert log_in(client).json()["user"]["email"] == "anna.kowalska@gmail.com"

    def test_minimal_profile(self, client, google):
        # The user can refuse to share the e-mail scope details; only "sub" is guaranteed.
        google.profile = {"sub": "333"}
        user = log_in(client).json()["user"]
        assert user["name"] == "333"
        assert user["email"] is None
        assert user["avatar_url"] is None

    def test_name_falls_back_to_email(self, client, google):
        del google.profile["name"]
        assert log_in(client).json()["user"]["name"] == "anna.kowalska@gmail.com"


class TestFailures:
    def test_state_from_another_session_is_rejected(self, client, google):
        state = start_login(client)["state"]
        client.cookies.clear()  # e.g. an attacker's callback link opened in the victim's browser
        response = google_redirects_back(client, state)
        assert response.status_code == 400
        assert google.requests == []  # the code was never exchanged

    def test_forged_state_is_rejected(self, client, google):
        start_login(client)
        assert google_redirects_back(client, "forged-state").status_code == 400
        assert google.requests == []

    def test_state_cannot_be_replayed(self, client, google):
        state = start_login(client)["state"]
        assert google_redirects_back(client, state).status_code == 200
        assert google_redirects_back(client, state).status_code == 400

    def test_user_cancels_on_consent_screen(self, client, db, google):
        state = start_login(client)["state"]
        response = google_redirects_back(client, state, error="access_denied")
        assert response.status_code == 400
        assert "access_denied" in response.json()["detail"]
        assert db.users.count_documents({}) == 0

    def test_code_rejected_by_google(self, client, db, google):
        google.token_status = 400
        response = log_in(client)
        assert response.status_code == 400
        assert db.users.count_documents({}) == 0

    def test_userinfo_unavailable(self, client, db, google):
        google.userinfo_status = 503
        assert log_in(client).status_code == 400
        assert db.users.count_documents({}) == 0

    def test_failure_is_reported_to_the_frontend(self, client, google):
        google.token_status = 400
        query = start_login(client, return_to="http://localhost:5173/auth_callback.html")
        response = google_redirects_back(client, query["state"])
        assert response.status_code == 302
        assert response.headers["location"] == "http://localhost:5173/auth_callback.html#error=login_failed"

    def test_success_is_sent_to_the_frontend_in_the_fragment(self, client, google):
        query = start_login(client, return_to="http://localhost:5173/auth_callback.html")
        response = google_redirects_back(client, query["state"])
        location = urlparse(response.headers["location"])
        assert location.query == ""
        fragment = parse_qs(location.fragment)
        assert client.get("/auth/me", headers=bearer(fragment["access_token"][0])).status_code == 200
        assert "google-access-token" not in json.dumps(dict(response.headers))  # Google's token stays with us
