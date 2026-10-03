"""Our own access tokens (JWT, HS256), issued after an OAuth login.

Stateless: the token carries user id, name and role, so authorizing a request needs no DB call.
Trade-off: a role change or ban takes effect when the user's current token expires (JWT_TTL_MINUTES).
"""

import logging
import secrets
from datetime import UTC, datetime, timedelta

import jwt

from app.config import settings
from app.models.user import AuthUser, Role

ALGORITHM = "HS256"
ISSUER = "hackyeah-api"

log = logging.getLogger(__name__)

if settings.jwt_secret is not None:
    _SECRET = settings.jwt_secret.get_secret_value()
else:
    _SECRET = secrets.token_urlsafe(32)
    log.warning("JWT_SECRET is not set: using a random secret, tokens will stop working after a restart")


def signing_secret() -> str:
    """Also signs the short-lived OAuth state cookie (SessionMiddleware)."""
    return _SECRET


class InvalidToken(Exception):
    pass


def create_access_token(user_id: str, name: str, role: Role, ttl: timedelta | None = None) -> tuple[str, int]:
    """Returns (token, lifetime in seconds)."""
    ttl = ttl if ttl is not None else timedelta(minutes=settings.jwt_ttl_minutes)
    now = datetime.now(UTC)
    claims = {"iss": ISSUER, "sub": user_id, "name": name, "role": str(role), "iat": now, "exp": now + ttl}
    return jwt.encode(claims, _SECRET, algorithm=ALGORITHM), int(ttl.total_seconds())


def decode_access_token(token: str) -> AuthUser:
    try:
        claims = jwt.decode(
            token, _SECRET, algorithms=[ALGORITHM], issuer=ISSUER, options={"require": ["exp", "iat", "sub", "iss"]}
        )
        return AuthUser(id=claims["sub"], name=claims.get("name") or claims["sub"], role=claims.get("role", Role.USER))
    except (jwt.InvalidTokenError, ValueError) as e:
        raise InvalidToken(str(e)) from e
