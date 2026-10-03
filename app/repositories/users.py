"""Users, created on first login and identified by (provider, provider's user id).

The same person logging in with GitHub and with Google gets two separate accounts – accounts are
not merged by e-mail (that would need a verified-email linking flow).
"""

from typing import Any

from pymongo import ReturnDocument
from pymongo.asynchronous.database import AsyncDatabase
from pymongo.errors import DuplicateKeyError

from app.auth.oauth import OAuthIdentity
from app.db import parse_object_id, utcnow
from app.models.user import Role, User

COLLECTION = "users"


async def ensure_indexes(db: AsyncDatabase) -> None:
    await db[COLLECTION].create_index([("identities.provider", 1), ("identities.subject", 1)], unique=True)


def _from_document(doc: dict[str, Any]) -> User:
    return User(
        id=str(doc["_id"]),
        name=doc["name"],
        email=doc.get("email"),
        avatar_url=doc.get("avatar_url"),
        role=doc.get("role", Role.USER),
        providers=[identity["provider"] for identity in doc.get("identities", [])],
        created_at=doc["created_at"],
        last_login_at=doc["last_login_at"],
    )


async def login(
    db: AsyncDatabase, identity: OAuthIdentity, *, admin_emails: set[str], role: Role | None = None
) -> User:
    """Creates the user on first login, refreshes the profile on later ones.

    Role: an explicit `role` wins (dev login); otherwise a verified e-mail from admin_emails makes
    the user an admin; otherwise a new user is a regular user and an existing one keeps their role
    (so an admin set by hand in the DB stays admin).
    """
    now = utcnow()
    to_set: dict[str, Any] = {"name": identity.name, "avatar_url": identity.avatar_url, "last_login_at": now}
    if identity.email and identity.email_verified:
        to_set["email"] = identity.email
    on_insert: dict[str, Any] = {
        "identities": [{"provider": identity.provider, "subject": identity.subject}],
        "created_at": now,
    }

    is_listed_admin = bool(identity.email_verified and identity.email and identity.email.lower() in admin_emails)
    if role is not None:
        to_set["role"] = str(role)
    elif is_listed_admin:
        to_set["role"] = str(Role.ADMIN)
    else:
        on_insert["role"] = str(Role.USER)

    query = {"identities": {"$elemMatch": {"provider": identity.provider, "subject": identity.subject}}}
    for attempt in range(2):
        try:
            doc = await db[COLLECTION].find_one_and_update(
                query, {"$set": to_set, "$setOnInsert": on_insert}, upsert=True, return_document=ReturnDocument.AFTER
            )
            return _from_document(doc)
        except DuplicateKeyError:
            # Two simultaneous first logins: the loser retries and finds the created user.
            if attempt:
                raise
    raise AssertionError("unreachable")


async def get_user(db: AsyncDatabase, user_id: str) -> User | None:
    oid = parse_object_id(user_id)
    doc = await db[COLLECTION].find_one({"_id": oid}) if oid else None
    return _from_document(doc) if doc else None
