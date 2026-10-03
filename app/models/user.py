from datetime import datetime
from enum import StrEnum
from typing import Annotated

from pydantic import BaseModel, Field, StringConstraints


class Role(StrEnum):
    USER = "user"
    ADMIN = "admin"


class AuthUser(BaseModel):
    """The caller, as stated by a verified access token."""

    id: str
    name: str
    role: Role = Role.USER

    @property
    def is_admin(self) -> bool:
        return self.role == Role.ADMIN


class User(BaseModel):
    id: str
    name: str
    email: str | None = None
    avatar_url: str | None = None
    role: Role
    providers: list[str] = Field(description="Login providers linked to this account, e.g. ['github']")
    created_at: datetime
    last_login_at: datetime


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    expires_in: int = Field(description="Seconds until the token expires")
    user: User


class DevLoginRequest(BaseModel):
    name: Annotated[str, StringConstraints(strip_whitespace=True, pattern=r"^[\w.-]{1,64}$")] = Field(
        description="Stable username; the same name always maps to the same user"
    )
    role: Role = Role.USER
