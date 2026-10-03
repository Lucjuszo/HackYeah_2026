"""Loads example places, ratings and comments into a running API.

    python scripts/seed.py                        # http://localhost:8000
    python scripts/seed.py --url http://host:8000

Goes through the HTTP API (not the DB), so it also works against a deployed instance.
Not idempotent: every run adds another copy of each place.
"""

import argparse
import json
import sys
from pathlib import Path

import httpx

PLACES_DIR = Path(__file__).resolve().parent.parent / "examples" / "places"

# (user id, score, comment or None) per place file; users are mock ids sent via X-User-Id.
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


def seed(base_url: str) -> None:
    with httpx.Client(base_url=base_url, timeout=10) as client:
        for path in sorted(PLACES_DIR.glob("*.json")):
            response = client.post("/places", json=json.loads(path.read_text(encoding="utf-8")))
            response.raise_for_status()
            place = response.json()

            for user, score, comment in REVIEWS.get(path.name, []):
                headers = {"X-User-Id": user}
                client.put(f"/places/{place['id']}/ratings/me", json={"score": score}, headers=headers).raise_for_status()
                if comment:
                    client.post(
                        f"/places/{place['id']}/comments", json={"text": comment}, headers=headers
                    ).raise_for_status()

            summary = client.get(f"/places/{place['id']}/ratings").json()
            average = f"{summary['average']:.2f}" if summary["average"] is not None else "–"
            print(f"{place['id']}  {place['name']:<28} rating {average} ({summary['count']})")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--url", default="http://localhost:8000")
    args = parser.parse_args()
    try:
        seed(args.url)
    except httpx.HTTPError as e:
        sys.exit(f"Seeding failed: {e}")


if __name__ == "__main__":
    main()
