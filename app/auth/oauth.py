"""OAuth login with GitHub and Google (authorization code flow, run by the backend).

The state parameter is kept in a short-lived signed session cookie (SessionMiddleware in main.py).
A provider is enabled when both its client id and secret are configured.
"""

from dataclasses import dataclass

from authlib.integrations.starlette_client import OAuth
from fastapi import Request

from app.config import settings

oauth = OAuth()

if settings.github_client_id and settings.github_client_secret:
    oauth.register(
        "github",
        client_id=settings.github_client_id,
        client_secret=settings.github_client_secret.get_secret_value(),
        authorize_url="https://github.com/login/oauth/authorize",
        access_token_url="https://github.com/login/oauth/access_token",
        api_base_url="https://api.github.com/",
        client_kwargs={"scope": "read:user user:email"},
    )

# Google: only non-sensitive scopes. With these the consent screen can be published "In production"
# for every Google account without Google's app verification (sensitive/restricted scopes would
# require it, and until then the app shows the "unverified app" warning and caps users at 100).
# Don't add scopes here without going through verification first (docs/AUTH.md).
GOOGLE_SCOPES = ("email", "profile")
GOOGLE_NON_SENSITIVE_SCOPES = frozenset(
    {
        "openid",
        "email",
        "profile",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
    }
)

if settings.google_client_id and settings.google_client_secret:
    # Plain OAuth with the userinfo endpoint (no "openid" scope / ID token to validate): the profile
    # comes straight from Google over TLS with the access token we just exchanged.
    oauth.register(
        "google",
        client_id=settings.google_client_id,
        client_secret=settings.google_client_secret.get_secret_value(),
        authorize_url="https://accounts.google.com/o/oauth2/v2/auth",
        access_token_url="https://oauth2.googleapis.com/token",
        api_base_url="https://www.googleapis.com/",
        client_kwargs={"scope": " ".join(GOOGLE_SCOPES)},
        # Let people with several Google accounts pick one instead of silently using the last one.
        authorize_params={"prompt": "select_account"},
    )


@dataclass
class OAuthIdentity:
    provider: str
    subject: str  # the provider's stable user id – never the e-mail, which can change
    name: str
    email: str | None
    email_verified: bool
    avatar_url: str | None


def _is_true(value: object) -> bool:
    """Google sends a JSON boolean, older endpoints the string "true"; bool("false") would be True."""
    return value is True or (isinstance(value, str) and value.lower() == "true")


def configured_providers() -> list[str]:
    return [name for name in ("github", "google") if oauth.create_client(name) is not None]


async def authorize_redirect(provider: str, request: Request, redirect_uri: str):
    return await oauth.create_client(provider).authorize_redirect(request, redirect_uri)


async def fetch_identity(provider: str, request: Request) -> OAuthIdentity:
    """Exchanges the callback's code for a token and loads the user's profile."""
    client = oauth.create_client(provider)
    token = await client.authorize_access_token(request)

    if provider == "github":
        user = (await client.get("user", token=token)).raise_for_status().json()
        emails = (await client.get("user/emails", token=token)).raise_for_status().json()
        primary = next((e for e in emails if e.get("primary") and e.get("verified")), None)
        return OAuthIdentity(
            provider="github",
            subject=str(user["id"]),
            name=user.get("name") or user["login"],
            email=primary["email"] if primary else None,
            email_verified=primary is not None,
            avatar_url=user.get("avatar_url"),
        )

    info = (await client.get("oauth2/v3/userinfo", token=token)).raise_for_status().json()
    return OAuthIdentity(
        provider="google",
        subject=info["sub"],
        name=info.get("name") or info.get("email") or info["sub"],
        email=info.get("email"),
        email_verified=_is_true(info.get("email_verified")),
        avatar_url=info.get("picture"),
    )
