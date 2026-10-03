from typing import Annotated

from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.auth.tokens import InvalidToken, decode_access_token
from app.models.user import AuthUser

# auto_error=False: we answer 401 (not FastAPI's default 403) with a WWW-Authenticate header.
_bearer = HTTPBearer(auto_error=False, description="Access token from /auth/{provider}/callback or /auth/dev-login")


def _unauthorized(detail: str) -> HTTPException:
    return HTTPException(status.HTTP_401_UNAUTHORIZED, detail, headers={"WWW-Authenticate": "Bearer"})


async def get_current_user(
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(_bearer)],
) -> AuthUser:
    if credentials is None:
        raise _unauthorized("Not authenticated")
    try:
        return decode_access_token(credentials.credentials)
    except InvalidToken:
        raise _unauthorized("Invalid or expired token")


CurrentUser = Annotated[AuthUser, Depends(get_current_user)]
