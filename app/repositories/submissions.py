"""Use the Mongo unique primary key to coalesce retries of a single creation."""
import hashlib
import json

from bson import ObjectId
from fastapi import HTTPException
from pymongo.errors import DuplicateKeyError


async def insert_creation(collection, doc, *, user, key, payload, scope):
    if key:
        identity = json.dumps([user, scope, key]).encode()
        doc["_id"] = ObjectId(hashlib.sha256(identity).digest()[:12])
        doc["submission_hash"] = hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()
    try:
        result = await collection.insert_one(doc)
    except DuplicateKeyError:
        old = await collection.find_one({"_id": doc["_id"]}) if key else None
        if old is None:
            raise
        if old.get("submission_hash") != doc["submission_hash"]:
            raise HTTPException(409, "Submission key already used for different content")
        return old
    doc["_id"] = result.inserted_id
    return doc
