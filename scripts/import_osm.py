"""Imports real cafes and restaurants in Kraków from OpenStreetMap, filling the gaps with demo data.

    python scripts/import_osm.py               # uses the snapshot in data/osm/ (fetches it if missing)
    python scripts/import_osm.py --refresh     # fetches fresh data from Overpass first
    python scripts/import_osm.py --count 40

Removes ALL mock data first (is_mock=true, including data from scripts/seed.py), then inserts
--count places, half cafes and half restaurants, marked is_mock=true. Name, address, coordinates,
the OSM link and every tag we can map (opening hours, wifi, wheelchair access, cuisine, ...) are
real; everything else is made up and listed in the place's `mock_fields`. Ratings and comments
are made up too (is_mock=true). Places whose OSM element is already linked to a real place are skipped.

Map data © OpenStreetMap contributors, available under the ODbL: https://www.openstreetmap.org/copyright
"""

import argparse
import asyncio
import json
import random
import sys
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))  # allow `python scripts/import_osm.py` from anywhere

import httpx  # noqa: E402
from bson import ObjectId  # noqa: E402
from pydantic import ValidationError  # noqa: E402
from pymongo.asynchronous.database import AsyncDatabase  # noqa: E402

from app.config import settings  # noqa: E402
from app.db import create_client  # noqa: E402
from app.models.place import Amenities, Place, PlaceCreate  # noqa: E402
from app.osm.mapping import OsmFacts, facts_from_element  # noqa: E402
from app.repositories import comments, places, ratings  # noqa: E402
from scripts import mock_content as mock  # noqa: E402
from scripts.seed import clear_mock_data  # noqa: E402

SNAPSHOT = ROOT / "data" / "osm" / "krakow-cafes-restaurants.json"
IMPORT_AUTHOR = "osm-import"
CITY = "Kraków"

# Public Overpass instances, tried in order (the main one is often overloaded).
OVERPASS_URLS = [
    "https://overpass-api.de/api/interpreter",
    "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
]
# Kraków's administrative boundary (wikidata Q31487); only named places with a street address.
QUERY = """
[out:json][timeout:90];
area["wikidata"="Q31487"]["boundary"="administrative"]->.krakow;
nwr["amenity"~"^(cafe|restaurant)$"]["name"]["addr:street"]["addr:housenumber"](area.krakow);
out center tags;
""".strip()


def fetch_snapshot() -> dict[str, Any]:
    errors = []
    for url in OVERPASS_URLS:
        try:
            response = httpx.post(
                url,
                data={"data": QUERY},
                headers={"User-Agent": "HackYeah2026-backend/0.1 (OSM import script)"},
                timeout=120,
            )
            response.raise_for_status()
            return {
                "source": url,
                "fetched_at": datetime.now(UTC).isoformat(timespec="seconds"),
                "license": "© OpenStreetMap contributors, ODbL 1.0",
                "query": QUERY,
                "elements": response.json()["elements"],
            }
        except (httpx.HTTPError, ValueError, KeyError) as e:
            errors.append(f"{url}: {e}")
    raise RuntimeError("All Overpass instances failed:\n  " + "\n  ".join(errors))


def load_elements(refresh: bool) -> list[dict[str, Any]]:
    if refresh or not SNAPSHOT.exists():
        snapshot = fetch_snapshot()
        SNAPSHOT.parent.mkdir(parents=True, exist_ok=True)
        SNAPSHOT.write_text(json.dumps(snapshot, ensure_ascii=False, indent=1), encoding="utf-8")
        print(f"Fetched {len(snapshot['elements'])} elements from {snapshot['source']}")
    return json.loads(SNAPSHOT.read_text(encoding="utf-8"))["elements"]


def candidates(elements: list[dict[str, Any]], rng: random.Random) -> list[OsmFacts]:
    """Usable places, one per name (no chain duplicates), the ones with the most real OSM data first."""
    usable: list[OsmFacts] = []
    seen_names: set[str] = set()
    for element in elements:
        try:
            facts = facts_from_element(element, default_city=CITY)
        except (ValueError, ValidationError):
            continue
        if facts.name.casefold() not in seen_names:
            seen_names.add(facts.name.casefold())
            usable.append(facts)
    rng.shuffle(usable)
    # Stable sort: places with equally rich data keep their shuffled order.
    usable.sort(key=lambda f: (f.opening_hours is None, -_richness(f)))
    return usable


def _richness(facts: OsmFacts) -> int:
    return len(facts.amenities) + len(facts.features) + (facts.address.postcode is not None)


def build_place(facts: OsmFacts, rng: random.Random) -> tuple[PlaceCreate, list[str]]:
    """Real OSM facts + mock values for the rest; returns the place and the list of mocked fields."""
    mock_fields: list[str] = []

    amenities = dict(facts.amenities)
    for flag in Amenities.model_fields:
        if flag not in amenities:
            amenities[flag] = mock.amenity(facts.kind, flag, rng)
            mock_fields.append(f"amenities.{flag}")

    opening_hours = facts.opening_hours
    if opening_hours is None:
        opening_hours = mock.opening_hours(facts.kind, rng)
        mock_fields.append("opening_hours")

    features = facts.features
    if not features:
        features = mock.features(facts.kind, rng)
        mock_fields.append("features")

    mock_fields += ["usage_price", "atmosphere", "menu"]
    place = PlaceCreate(
        name=facts.name,
        address=facts.address,
        coordinates=facts.coordinates,
        amenities=amenities,
        opening_hours=opening_hours,
        usage_price=mock.usage_price(facts.kind, rng),
        atmosphere=mock.atmosphere(facts.kind, rng),
        features=features,
        menu=mock.menu(facts.kind, facts.cuisines, rng),
        osm=facts.osm,
    )
    return place, mock_fields


async def import_places(
    db: AsyncDatabase, elements: list[dict[str, Any]], count: int, seed: int = 2026
) -> tuple[int, list[Place]]:
    """Returns (number of old mock places removed, imported places)."""
    for repo in (places, ratings, comments):
        await repo.ensure_indexes(db)
    removed = await clear_mock_data(db)

    wanted = {"cafe": count // 2, "restaurant": count - count // 2}
    imported: list[Place] = []
    for facts in candidates(elements, random.Random(seed)):
        if wanted[facts.kind] == 0:
            continue
        # Per-place RNG: the same OSM element always gets the same mock values.
        rng = random.Random(f"{seed}:{facts.osm.type}/{facts.osm.id}")
        payload, mock_fields = build_place(facts, rng)
        try:
            place = await places.create_place(db, payload, IMPORT_AUTHOR, is_mock=True, mock_fields=mock_fields)
        except places.PlaceAlreadyExists:
            continue  # a real place already links this OSM element
        place_id = ObjectId(place.id)
        for user, score, text in mock.reviews(rng):
            await ratings.set_rating(db, place_id, user, score, is_mock=True)
            if text:
                await comments.create_comment(db, place_id, user, text, score=score, user_name=user, is_mock=True)
        imported.append(await places.get_place(db, place.id))
        wanted[facts.kind] -= 1
        if not any(wanted.values()):
            break
    return removed, imported


async def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--count", type=int, default=30)
    parser.add_argument("--refresh", action="store_true", help="fetch fresh data from Overpass")
    args = parser.parse_args()

    elements = load_elements(args.refresh)
    print(f"Importing into {settings.mongo_target()}")
    client = create_client()
    try:
        removed, imported = await import_places(client[settings.mongo_db], elements, args.count)
    finally:
        await client.close()

    print(f"Removed {removed} old mock place(s), imported {len(imported)}:")
    for place in imported:
        real_amenities = sum(f"amenities.{flag}" not in place.mock_fields for flag in Amenities.model_fields)
        hours = "mock" if "opening_hours" in place.mock_fields else "OSM"
        street = f"{place.address.street} {place.address.house_number}"
        print(f"  {place.name[:30]:<30} {street[:28]:<28} hours: {hours:<4}  real amenities: {real_amenities}/7")


if __name__ == "__main__":
    asyncio.run(main())
