from datetime import UTC, datetime

from pymongo import AsyncMongoClient
from pymongo.asynchronous.database import AsyncDatabase

from app.config import settings

# tz_aware: return UTC-aware datetimes instead of naive ones, matching what we write.
client: AsyncMongoClient = AsyncMongoClient(settings.mongo_uri, tz_aware=True)


def get_db() -> AsyncDatabase:
    return client[settings.mongo_db]


def utcnow() -> datetime:
    """Current UTC time truncated to milliseconds – BSON's precision – so values read back match values written."""
    now = datetime.now(UTC)
    return now.replace(microsecond=now.microsecond // 1000 * 1000)
