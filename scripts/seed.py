"""Idempotently load the verified Gdańsk libraries into the configured MongoDB."""

import asyncio
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))  # allow `python scripts/seed.py` from anywhere

from pymongo.asynchronous.database import AsyncDatabase  # noqa: E402

from app.config import settings  # noqa: E402
from app.db import create_client  # noqa: E402
from app.models.place import Place  # noqa: E402
from app.repositories import places  # noqa: E402

from app.verified_places import load_verified_places  # noqa: E402

PLACES_DIR = ROOT / "examples" / "places"


async def seed(db: AsyncDatabase) -> list[Place]:
    await places.ensure_indexes(db)
    return await load_verified_places(db, PLACES_DIR)


async def main() -> None:
    print(f"Seeding {settings.mongo_target()}")
    client = create_client()
    try:
        seeded = await seed(client[settings.mongo_db])
    finally:
        await client.close()

    print(f"Verified library listings: {len(seeded)}")
    for place in seeded:
        average = f"{place.rating.average:.2f}" if place.rating.average is not None else "–"
        print(f"  {place.id}  {place.name:<28} rating {average} ({place.rating.count})")


if __name__ == "__main__":
    asyncio.run(main())
