from datetime import UTC, datetime

from bson import ObjectId
from pymongo import AsyncMongoClient
from pymongo.asynchronous.database import AsyncDatabase

from app.config import Settings, settings


def create_client(config: Settings = settings) -> AsyncMongoClient:
    uri, kwargs = config.mongo_connection()
    # tz_aware: return UTC-aware datetimes instead of naive ones, matching what we write.
    return AsyncMongoClient(uri, tz_aware=True, **kwargs)


client: AsyncMongoClient = create_client()


def get_db() -> AsyncDatabase:
    return client[settings.mongo_db]


def utcnow() -> datetime:
    """Current UTC time truncated to milliseconds – BSON's precision – so values read back match values written."""
    now = datetime.now(UTC)
    return now.replace(microsecond=now.microsecond // 1000 * 1000)


def parse_object_id(value: str) -> ObjectId | None:
    return ObjectId(value) if ObjectId.is_valid(value) else None
