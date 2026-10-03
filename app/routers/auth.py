from urllib.parse import urlencode

from authlib.integrations.base_client.errors import OAuthError
from fastapi import APIRouter, HTTPException, Request, status
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


@router.get("/{provider}/login", name="oauth_login")
async def oauth_login(provider: str, request: Request):
    """Redirects the browser to the provider's consent screen."""
    _require_provider(provider)
    redirect_uri = str(request.url_for("oauth_callback", provider=provider))
    return await oauth_flow.authorize_redirect(provider, request, redirect_uri)


@router.get("/{provider}/callback", name="oauth_callback", response_model=TokenResponse)
async def oauth_callback(provider: str, request: Request, db: Db):
    """The provider sends the browser back here; we log the user in and issue our access token.

    With AUTH_REDIRECT_URL set, redirects to the frontend with `#access_token=...&expires_in=...`;
    otherwise answers with the token as JSON (for testing without a frontend).
    """
    _require_provider(provider)
    if error := request.query_params.get("error"):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, f"Login was not completed: {error}")
    try:
        identity = await oauth_flow.fetch_identity(provider, request)
    except (OAuthError, HTTPError) as e:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, f"Login with {provider} failed: {e}")

    user = await repo.login(db, identity, admin_emails=settings.admin_email_set())
    response = _token_response(user)
    if settings.auth_redirect_url:
        # Fragment, not query: it never reaches servers or logs on the way to the frontend.
        fragment = urlencode({"access_token": response.access_token, "expires_in": response.expires_in})
        return RedirectResponse(f"{settings.auth_redirect_url}#{fragment}", status.HTTP_302_FOUND)
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
