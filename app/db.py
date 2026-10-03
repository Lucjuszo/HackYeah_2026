from datetime import UTC, datetime
from zoneinfo import ZoneInfo

from bson import ObjectId
from pymongo import AsyncMongoClient
from pymongo.asynchronous.database import AsyncDatabase

from app.config import Settings, settings


def create_client(config: Settings = settings) -> AsyncMongoClient:
    uri, kwargs = config.mongo_connection()
    # tz_aware: return UTC-aware datetimes instead of naive ones, matching what we write.
    # 10 s instead of the default 30 s: an unreachable database should fail fast.
    return AsyncMongoClient(uri, tz_aware=True, serverSelectionTimeoutMS=10_000, **kwargs)


client: AsyncMongoClient = create_client()


def get_db() -> AsyncDatabase:
    return client[settings.mongo_db]


def utcnow() -> datetime:
    """Current UTC time truncated to milliseconds – BSON's precision – so values read back match values written."""
    now = datetime.now(UTC)
    return now.replace(microsecond=now.microsecond // 1000 * 1000)


def local_now() -> datetime:
    """Current time in TIMEZONE, the zone of places' opening hours."""
    return datetime.now(ZoneInfo(settings.timezone))


def parse_object_id(value: str) -> ObjectId | None:
    return ObjectId(value) if ObjectId.is_valid(value) else None
