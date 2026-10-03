from datetime import UTC, datetime, timedelta
from urllib.parse import parse_qs, urlparse

import jwt
import pytest
from authlib.integrations.base_client.errors import OAuthError

from app.auth import oauth as oauth_flow
from app.auth.tokens import ALGORITHM, ISSUER, create_access_token
from app.config import settings
from app.models.user import Role
from tests.helpers import ANONYMOUS, as_user


def bearer(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def identity(provider="github", subject="42", name="Anna", email="anna@example.com", verified=True):
    return oauth_flow.OAuthIdentity(
        provider=provider, subject=subject, name=name, email=email, email_verified=verified, avatar_url=None
    )


@pytest.fixture
def fake_provider(monkeypatch):
    """Makes the OAuth callback return the identity stored in the fixture instead of calling the provider."""
    state = {"identity": identity()}

    async def fake_fetch_identity(provider, request):
        if isinstance(state["identity"], Exception):
            raise state["identity"]
        return state["identity"]

    monkeypatch.setattr(oauth_flow, "fetch_identity", fake_fetch_identity)
    return state


def callback(client, provider="github", **params):
    return client.get(
        f"/auth/{provider}/callback", params={"code": "c", "state": "s", **params}, headers=ANONYMOUS,
        follow_redirects=False,
    )


class TestTokens:
    def test_valid_token_accepted(self, client, minimal_payload):
        assert client.post("/places", json=minimal_payload, headers=as_user("anna")).status_code == 201

    def claims(self, **overrides):
        now = datetime.now(UTC)
        return {"iss": ISSUER, "sub": "anna", "name": "anna", "role": "user", "iat": now,
                "exp": now + timedelta(hours=1), **overrides}

    @pytest.mark.parametrize(
        "headers",
        [
            ANONYMOUS,
            {"Authorization": "Bearer"},
            {"Authorization": "Bearer not-a-jwt"},
            {"Authorization": "Basic YW5uYTpwYXNz"},
        ],
        ids=["missing", "empty bearer", "garbage", "wrong scheme"],
    )
    def test_rejected_headers(self, client, minimal_payload, headers):
        response = client.post("/places", json=minimal_payload, headers=headers)
        assert response.status_code == 401
        assert response.headers["www-authenticate"] == "Bearer"

    def test_expired(self, client, minimal_payload):
        token, _ = create_access_token("anna", "anna", Role.USER, ttl=timedelta(seconds=-1))
        assert client.post("/places", json=minimal_payload, headers=bearer(token)).status_code == 401

    def test_wrong_secret(self, client, minimal_payload):
        token = jwt.encode(self.claims(), "some-other-secret-of-sufficient-length!!", algorithm=ALGORITHM)
        assert client.post("/places", json=minimal_payload, headers=bearer(token)).status_code == 401

    def test_wrong_issuer(self, client, minimal_payload):
        token = jwt.encode(self.claims(iss="someone-else"), settings.jwt_secret.get_secret_value(), algorithm=ALGORITHM)
        assert client.post("/places", json=minimal_payload, headers=bearer(token)).status_code == 401

    def test_unsigned_token(self, client, minimal_payload):
        token = jwt.encode(self.claims(role="admin"), key=None, algorithm="none")
        assert client.post("/places", json=minimal_payload, headers=bearer(token)).status_code == 401

    def test_reads_are_public(self, client, created_place):
        assert client.get("/places", headers=ANONYMOUS).status_code == 200
        assert client.get(f"/places/{created_place['id']}", headers=ANONYMOUS).status_code == 200
        assert client.get(f"/places/{created_place['id']}/ratings", headers=ANONYMOUS).status_code == 200

    @pytest.mark.parametrize(
        ("method", "path"),
        [("post", "/places"), ("patch", "/places/{id}"), ("put", "/places/{id}/ratings/me"),
         ("delete", "/places/{id}/ratings/me"), ("post", "/places/{id}/comments"), ("post", "/places/{id}/photos")],
    )
    def test_writes_require_login(self, client, created_place, method, path):
        response = client.request(method, path.format(id=created_place["id"]), json={}, headers=ANONYMOUS)
        assert response.status_code == 401


class TestProviders:
    def test_list(self, client):
        body = client.get("/auth/providers", headers=ANONYMOUS).json()
        assert [p["name"] for p in body["providers"]] == ["github", "google"]
        assert body["providers"][0]["login_url"] == "http://testserver/auth/github/login"
        assert body["dev_login"] is False

    @pytest.mark.parametrize(
        ("provider", "authorize_url", "client_id", "scope"),
        [
            ("github", "https://github.com/login/oauth/authorize", "test-github-client", "read:user user:email"),
            ("google", "https://accounts.google.com/o/oauth2/v2/auth", "test-google-client", "email profile"),
        ],
    )
    def test_login_redirects_to_provider(self, client, provider, authorize_url, client_id, scope):
        response = client.get(f"/auth/{provider}/login", headers=ANONYMOUS, follow_redirects=False)
        assert response.status_code == 302
        location = urlparse(response.headers["location"])
        query = parse_qs(location.query)
        assert f"{location.scheme}://{location.netloc}{location.path}" == authorize_url
        assert query["client_id"] == [client_id]
        assert query["redirect_uri"] == [f"http://testserver/auth/{provider}/callback"]
        assert query["scope"] == [scope]
        assert query["state"][0]  # anti-CSRF state, kept in the session cookie
        assert "session" in response.cookies

    @pytest.mark.parametrize("path", ["/auth/facebook/login", "/auth/facebook/callback"])
    def test_unknown_provider(self, client, path):
        assert client.get(path, headers=ANONYMOUS).status_code == 404


class TestCallback:
    def test_creates_user_and_returns_token(self, client, db, fake_provider):
        response = callback(client)
        assert response.status_code == 200, response.text
        body = response.json()
        assert body["token_type"] == "bearer"
        assert body["expires_in"] == settings.jwt_ttl_minutes * 60
        user = body["user"]
        assert (user["name"], user["email"], user["role"], user["providers"]) == (
            "Anna", "anna@example.com", "user", ["github"]
        )

        me = client.get("/auth/me", headers=bearer(body["access_token"])).json()
        assert me == user
        assert db.users.count_documents({}) == 1

    def test_token_works_for_writes(self, client, fake_provider, minimal_payload):
        body = callback(client).json()
        place = client.post("/places", json=minimal_payload, headers=bearer(body["access_token"])).json()
        assert place["created_by"] == body["user"]["id"]

    def test_second_login_reuses_user_and_refreshes_profile(self, client, db, fake_provider):
        first = callback(client).json()["user"]
        fake_provider["identity"] = identity(name="Anna K.")
        second = callback(client).json()["user"]
        assert second["id"] == first["id"]
        assert second["name"] == "Anna K."
        assert second["created_at"] == first["created_at"]
        assert db.users.count_documents({}) == 1

    def test_same_subject_on_other_provider_is_another_user(self, client, db, fake_provider):
        github_user = callback(client, "github").json()["user"]
        fake_provider["identity"] = identity(provider="google")
        google_user = callback(client, "google").json()["user"]
        assert github_user["id"] != google_user["id"]
        assert google_user["providers"] == ["google"]

    def test_admin_email_gets_admin_role(self, client, fake_provider):
        fake_provider["identity"] = identity(email="Boss@Example.com")
        assert callback(client).json()["user"]["role"] == "admin"

    def test_unverified_admin_email_is_not_admin(self, client, fake_provider):
        fake_provider["identity"] = identity(email="boss@example.com", verified=False)
        user = callback(client).json()["user"]
        assert user["role"] == "user"
        assert user["email"] is None  # unverified e-mails aren't stored

    def test_admin_set_in_db_stays_admin(self, client, db, fake_provider):
        user = callback(client).json()["user"]
        db.users.update_one({}, {"$set": {"role": "admin"}})
        assert callback(client).json()["user"]["role"] == "admin"
        assert user["role"] == "user"

    def test_admin_token_can_moderate(self, client, created_place, fake_provider):
        comment = client.post(f"/places/{created_place['id']}/comments", json={"text": "x"}).json()
        fake_provider["identity"] = identity(email="boss@example.com")
        token = callback(client).json()["access_token"]
        response = client.delete(f"/places/{created_place['id']}/comments/{comment['id']}", headers=bearer(token))
        assert response.status_code == 204

    def test_provider_error(self, client, fake_provider):
        response = callback(client, error="access_denied")
        assert response.status_code == 400
        assert "access_denied" in response.json()["detail"]

    def test_exchange_failure(self, client, fake_provider):
        fake_provider["identity"] = OAuthError(error="mismatching_state")
        assert callback(client).status_code == 400

    def test_redirects_to_frontend_when_configured(self, client, fake_provider, monkeypatch):
        monkeypatch.setattr(settings, "auth_redirect_url", "http://localhost:3000/auth/done")
        response = callback(client)
        assert response.status_code == 302
        location = urlparse(response.headers["location"])
        assert f"{location.scheme}://{location.netloc}{location.path}" == "http://localhost:3000/auth/done"
        assert location.query == ""
        fragment = parse_qs(location.fragment)
        token = fragment["access_token"][0]
        assert client.get("/auth/me", headers=bearer(token)).status_code == 200


class TestDevLogin:
    def test_disabled_by_default(self, client):
        assert client.post("/auth/dev-login", json={"name": "anna"}, headers=ANONYMOUS).status_code == 404

    def test_issues_tokens_when_enabled(self, client, db, monkeypatch):
        monkeypatch.setattr(settings, "auth_dev_login", True)
        anna = client.post("/auth/dev-login", json={"name": "anna"}, headers=ANONYMOUS).json()
        admin = client.post("/auth/dev-login", json={"name": "boss", "role": "admin"}, headers=ANONYMOUS).json()
        again = client.post("/auth/dev-login", json={"name": "anna"}, headers=ANONYMOUS).json()

        assert anna["user"]["role"] == "user"
        assert admin["user"]["role"] == "admin"
        assert again["user"]["id"] == anna["user"]["id"]
        assert anna["user"]["providers"] == ["dev"]
        assert client.get("/auth/me", headers=bearer(admin["access_token"])).json()["role"] == "admin"
        assert db.users.count_documents({}) == 2

    @pytest.mark.parametrize("name", ["", "two words", "a" * 65, "x/y"])
    def test_invalid_name(self, client, monkeypatch, name):
        monkeypatch.setattr(settings, "auth_dev_login", True)
        assert client.post("/auth/dev-login", json={"name": name}, headers=ANONYMOUS).status_code == 422


def test_me_requires_login(client):
    assert client.get("/auth/me", headers=ANONYMOUS).status_code == 401


def test_me_for_unknown_user(client):
    # A validly signed token whose user is gone from the DB.
    assert client.get("/auth/me", headers=as_user("000000000000000000000000")).status_code == 404
