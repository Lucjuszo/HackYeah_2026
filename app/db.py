from pymongo import AsyncMongoClient
from pymongo.asynchronous.database import AsyncDatabase

from app.config import settings

client: AsyncMongoClient = AsyncMongoClient(settings.mongo_uri)


def get_db() -> AsyncDatabase:
    return client[settings.mongo_db]
