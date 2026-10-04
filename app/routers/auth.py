import re
from typing import Annotated
from urllib.parse import urlencode, urlparse

from authlib.integrations.base_client.errors import OAuthError
from fastapi import APIRouter, HTTPException, Query, Request, status
from fastapi.responses import RedirectResponse
from httpx import HTTPError

from app.auth import CurrentUser
from app.auth import oauth as oauth_flow
from app.auth.tokens import create_access_token
from app.config import settings
from app.models.user import AuthProviders, DevLoginRequest, LoginProvider, TokenResponse, User
from app.repositories import users as repo
from app.routers.deps import Db

router = APIRouter(prefix="/auth", tags=["auth"])


def _token_response(user: User) -> TokenResponse:
    token, expires_in = create_access_token(user.id, user.name, user.role)
    return TokenResponse(access_token=token, expires_in=expires_in, user=user)


def _require_provider(provider: str) -> None:
    if provider not in oauth_flow.configured_providers():
        raise HTTPException(status.HTTP_404_NOT_FOUND, f"Login provider '{provider}' is not configured")


@router.get("/providers")
async def list_providers(request: Request) -> AuthProviders:
    """Configured login options; the frontend sends the browser to `login_url`."""
    return AuthProviders(
        providers=[
            LoginProvider(name=name, login_url=str(request.url_for("oauth_login", provider=name)))
            for name in oauth_flow.configured_providers()
        ],
        dev_login=settings.auth_dev_login,
    )


RETURN_KEY = "auth_return_to"


def _provider_callback_url(provider: str, request: Request) -> str:
    """Return the exact provider callback URI registered in the OAuth app."""
    if settings.oauth_callback_base_url:
        return f"{settings.oauth_callback_base_url.rstrip('/')}/auth/{provider}/callback"
    return str(request.url_for("oauth_callback", provider=provider))


def _is_allowed_return_url(url: str) -> bool:
    """Only frontends we trust may receive tokens: CORS origins, AUTH_REDIRECT_URL's origin and,
    with CORS_ALLOW_LOCALHOST, localhost on any port (Flutter web / the desktop app's loopback page)."""
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https") or not parsed.netloc or parsed.username or parsed.password:
        return False
    origin = f"{parsed.scheme}://{parsed.netloc}"
    allowed = set(settings.cors_origin_list())
    if settings.auth_redirect_url:
        configured = urlparse(settings.auth_redirect_url)
        allowed.add(f"{configured.scheme}://{configured.netloc}")
    regex = settings.cors_origin_regex()
    return origin in allowed or bool(regex and re.fullmatch(regex, origin))


def _redirect_with(url: str, **params: str | int) -> RedirectResponse:
    # Fragment, not query: it never reaches servers or logs on the way to the frontend.
    return RedirectResponse(f"{url.split('#', 1)[0]}#{urlencode(params)}", status.HTTP_302_FOUND)


@router.get("/{provider}/login", name="oauth_login")
async def oauth_login(
    provider: str,
    request: Request,
    return_to: Annotated[
        str | None,
        Query(
            description="Frontend page to send the token to (#access_token=...); overrides AUTH_REDIRECT_URL. "
            "Must be an allowed frontend origin (CORS_ORIGINS / localhost)."
        ),
    ] = None,
):
    """Redirects the browser to the provider's consent screen."""
    _require_provider(provider)
    if return_to is not None and not _is_allowed_return_url(return_to):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "return_to is not an allowed frontend address")
    if return_to is not None:
        request.session[RETURN_KEY] = return_to
    else:
        request.session.pop(RETURN_KEY, None)
    redirect_uri = _provider_callback_url(provider, request)
    return await oauth_flow.authorize_redirect(provider, request, redirect_uri)


@router.get("/{provider}/callback", name="oauth_callback", response_model=TokenResponse)
async def oauth_callback(provider: str, request: Request, db: Db):
    """The provider sends the browser back here; we log the user in and issue our access token.

    Redirects to the frontend with `#access_token=...&expires_in=...` (or `#error=...`): to the
    `return_to` given at /login, else AUTH_REDIRECT_URL. Without either it answers with JSON
    (for testing without a frontend).
    """
    _require_provider(provider)
    target = request.session.pop(RETURN_KEY, None) or settings.auth_redirect_url
    if error := request.query_params.get("error"):  # e.g. the user clicked "Cancel"
        if target:
            return _redirect_with(target, error=error)
        raise HTTPException(status.HTTP_400_BAD_REQUEST, f"Login was not completed: {error}")
    try:
        identity = await oauth_flow.fetch_identity(provider, request)
    except (OAuthError, HTTPError) as e:
        if target:
            return _redirect_with(target, error="login_failed")
        raise HTTPException(status.HTTP_400_BAD_REQUEST, f"Login with {provider} failed: {e}")

    user = await repo.login(db, identity, admin_emails=settings.admin_email_set())
    response = _token_response(user)
    if target:
        return _redirect_with(target, access_token=response.access_token, expires_in=response.expires_in)
    return response


@router.post("/dev-login")
async def dev_login(body: DevLoginRequest, db: Db) -> TokenResponse:
    """DEV ONLY (AUTH_DEV_LOGIN=true): a token for any user name and role, no OAuth involved."""
    if not settings.auth_dev_login:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Not Found")
    identity = oauth_flow.OAuthIdentity(
        provider="dev", subject=body.name, name=body.name, email=None, email_verified=False, avatar_url=None
    )
    user = await repo.login(db, identity, admin_emails=set(), role=body.role)
    return _token_response(user)


@router.get("/me")
async def me(user: CurrentUser, db: Db) -> User:
    profile = await repo.get_user(db, user.id)
    if profile is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "User not found")
    return profile
