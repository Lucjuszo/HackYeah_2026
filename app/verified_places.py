from pathlib import Path

from pymongo.asynchronous.database import AsyncDatabase

from app.models.place import Place, PlaceCreate
from app.repositories import places

SEED_AUTHOR = "seed"


async def load_verified_places(db: AsyncDatabase, directory: Path) -> list[Place]:
    seeded = []
    for path in sorted(directory.iterdir()):
        payload = PlaceCreate.model_validate_json(path.read_text(encoding="utf-8"))
        # Keep IDs, moderation decisions, edits and reviews from earlier seed versions.
        existing = await db[places.COLLECTION].find_one({
            "created_by": SEED_AUTHOR, "name": payload.name, "address.city": payload.address.city,
        })
        if existing:
            if existing.get("is_mock"):
                await db[places.COLLECTION].update_one({"_id": existing["_id"]}, {"$set": {"is_mock": False}})
                existing["is_mock"] = False
            seeded.append(places.from_document(existing))
        else:
            seeded.append(await places.create_place(db, payload, SEED_AUTHOR, request_key=path.stem))
    return seeded
