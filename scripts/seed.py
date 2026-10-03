"""Loads the example places, ratings and comments straight into MongoDB, marked with is_mock=true.

    python scripts/seed.py                          # database from .env (remote by default)
    USE_REMOTE_MONGO=false python scripts/seed.py   # docker compose container

Safe to re-run: mock data from previous runs (and ratings/comments attached to mock places)
is removed first. Documents without is_mock=true are never touched.
"""

import asyncio
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))  # allow `python scripts/seed.py` from anywhere

from bson import ObjectId  # noqa: E402
from pymongo.asynchronous.database import AsyncDatabase  # noqa: E402

from app.config import settings  # noqa: E402
from app.db import create_client  # noqa: E402
from app.models.place import Place, PlaceCreate  # noqa: E402
from app.repositories import comments, places, ratings  # noqa: E402

PLACES_DIR = ROOT / "examples" / "places"
SEED_AUTHOR = "seed"

# (user id, score, comment or None) per place file; user ids are mock ids.
REVIEWS: dict[str, list[tuple[str, int, str | None]]] = {
    "01-kawiarnia-pod-kodem.json": [
        ("anna", 5, "Najlepszy flat white w okolicy, gniazdka przy każdym stoliku."),
        ("bartek", 4, "Fajnie się pracuje, ale w weekend ciężko o miejsce."),
        ("celina", 5, None),
    ],
    "02-czytelnia-kazimierz.json": [
        ("anna", 5, "Idealna cisza przed sesją."),
        ("dawid", 4, "Brakuje klimy latem."),
    ],
    "03-cowork-hub-zablocie.json": [
        ("bartek", 4, "Drogo, ale pokoje wygłuszane ratują calle."),
        ("ewa", 3, None),
        ("dawid", 5, "Całodobowo – uratowało mi hackathon."),
    ],
    "04-nocna-stolowka.json": [
        ("celina", 4, "Pierogi o 2 w nocy, czego chcieć więcej."),
        ("ewa", 2, "Głośno i brak gniazdek, do pracy się nie nadaje."),
    ],
    "05-antykwariat-i-kawa.json": [
        ("anna", 4, "Klimatyczne miejsce, mało stolików."),
    ],
    "06-kawiarnia-na-powislu.json": [],
}


async def clear_mock_data(db: AsyncDatabase) -> int:
    """Removes mock places with everything attached to them; returns the number of places removed."""
    mock_place_ids = await db[places.COLLECTION].distinct("_id", {"is_mock": True})
    attached = {"place_id": {"$in": mock_place_ids}}
    await db[ratings.COLLECTION].delete_many(attached)
    await db[comments.COLLECTION].delete_many(attached)
    result = await db[places.COLLECTION].delete_many({"is_mock": True})
    return result.deleted_count


async def seed(db: AsyncDatabase) -> tuple[int, list[Place]]:
    """Returns (number of old mock places removed, freshly seeded places)."""
    for repo in (places, ratings, comments):
        await repo.ensure_indexes(db)
    removed = await clear_mock_data(db)

    seeded = []
    for path in sorted(PLACES_DIR.glob("*.json")):
        payload = PlaceCreate.model_validate_json(path.read_text(encoding="utf-8"))
        place = await places.create_place(db, payload, SEED_AUTHOR, is_mock=True)
        place_id = ObjectId(place.id)
        for user, score, text in REVIEWS.get(path.name, []):
            await ratings.set_rating(db, place_id, user, score, is_mock=True)
            if text:
                await comments.create_comment(db, place_id, user, text, is_mock=True)
        seeded.append(await places.get_place(db, place.id))
    return removed, seeded


async def main() -> None:
    print(f"Seeding {settings.mongo_target()}")
    client = create_client()
    try:
        removed, seeded = await seed(client[settings.mongo_db])
    finally:
        await client.close()

    print(f"Removed {removed} old mock place(s), added {len(seeded)}:")
    for place in seeded:
        average = f"{place.rating.average:.2f}" if place.rating.average is not None else "–"
        print(f"  {place.id}  {place.name:<28} rating {average} ({place.rating.count})")


if __name__ == "__main__":
    asyncio.run(main())
