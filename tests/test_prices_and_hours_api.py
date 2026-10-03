"""Price filters (min_price / max_price, price_range) and opening status (closes_at / opens_at) via the API."""

from datetime import datetime
from zoneinfo import ZoneInfo

import pytest
from bson import ObjectId

from app.models.place import PriceRange, parse_usage_price
from app.repositories import places as repo
from app.routers import places as places_router
from tests.test_places_api import RYNEK, add_place

WEDNESDAY_AFTERNOON = datetime(2026, 10, 7, 14, 30, tzinfo=ZoneInfo("Europe/Warsaw"))
WEDNESDAY_NIGHT = datetime(2026, 10, 7, 23, 0, tzinfo=ZoneInfo("Europe/Warsaw"))
OFFICE_HOURS = {"periods": [{"day": d, "open": "08:00", "close": "18:00"} for d in range(5)]}


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("0-30", (0, 30)),
        ("30 - 60 zł", (30, 60)),
        ("5–15 PLN", (5, 15)),
        ("60+", (60, None)),
        ("20", (20, 20)),
        ("30-0", (0, 30)),
        ("za darmo", (0, 0)),
        ("Bezpłatne", (0, 0)),
        ("0", (0, 0)),
    ],
)
def test_parse_usage_price(text, expected):
    assert parse_usage_price(text) == PriceRange(min=expected[0], max=expected[1])


@pytest.mark.parametrize("text", [None, "tanio", "zależy", "-5", "1-2-3"])
def test_unparsable_usage_price(text):
    assert parse_usage_price(text) is None


def names(response) -> list[str]:
    assert response.status_code == 200, response.text
    return sorted(p["name"] for p in response.json())


@pytest.fixture
def priced(client, minimal_payload):
    for name, price in [("free", "za darmo"), ("cheap", "0-30"), ("mid", "30-60"), ("pricey", "60+"), ("vague", "tanio")]:
        add_place(client, minimal_payload, name, RYNEK, usage_price=price)
    add_place(client, minimal_payload, "unknown", RYNEK)


class TestPriceFilters:
    def test_price_range_in_responses(self, client, minimal_payload):
        place = add_place(client, minimal_payload, "cafe", RYNEK, usage_price="30-60")
        assert place["price_range"] == {"min": 30, "max": 60}
        assert client.get(f"/places/{place['id']}").json()["price_range"] == {"min": 30, "max": 60}
        assert client.get("/places/summary").json()[0]["price_range"] == {"min": 30, "max": 60}

    def test_free_text_has_no_range(self, client, minimal_payload):
        assert add_place(client, minimal_payload, "x", RYNEK, usage_price="tanio")["price_range"] is None
        assert add_place(client, minimal_payload, "y", RYNEK)["price_range"] is None

    # Frontend chips: Bezpłatne / Do 30 zł / Powyżej 30 zł
    def test_free(self, client, priced):
        assert names(client.get("/places", params={"max_price": 0})) == ["free"]

    def test_up_to_30(self, client, priced):
        assert names(client.get("/places", params={"max_price": 30})) == ["cheap", "free"]

    def test_from_30(self, client, priced):
        assert names(client.get("/places", params={"min_price": 30})) == ["mid", "pricey"]

    def test_between(self, client, priced):
        assert names(client.get("/places", params={"min_price": 30, "max_price": 60})) == ["mid"]

    def test_summary_and_total(self, client, priced):
        response = client.get("/places/summary", params={"max_price": 30})
        assert names(response) == ["cheap", "free"]
        assert response.headers["X-Total-Count"] == "2"

    def test_invalid(self, client):
        assert client.get("/places", params={"min_price": 60, "max_price": 30}).status_code == 422
        assert client.get("/places", params={"max_price": -1}).status_code == 422

    def test_update_recomputes_range(self, client, minimal_payload):
        place = add_place(client, minimal_payload, "cafe", RYNEK, usage_price="0-30")
        url = f"/places/{place['id']}"
        assert client.patch(url, json={"usage_price": "60+"}).json()["price_range"] == {"min": 60, "max": None}
        assert names(client.get("/places", params={"min_price": 60})) == ["cafe"]
        assert client.patch(url, json={"usage_price": None}).json()["price_range"] is None
        assert names(client.get("/places", params={"min_price": 0})) == []

    def test_other_updates_keep_range(self, client, minimal_payload):
        place = add_place(client, minimal_payload, "cafe", RYNEK, usage_price="0-30")
        updated = client.patch(f"/places/{place['id']}", json={"name": "Kawiarnia"}).json()
        assert updated["price_range"] == {"min": 0, "max": 30}

    def test_backfill_of_old_documents(self, client, minimal_payload, db):
        place = add_place(client, minimal_payload, "old", RYNEK, usage_price="30-60")
        db.places.update_one({"_id": ObjectId(place["id"])}, {"$unset": {"price_range": ""}})
        assert names(client.get("/places", params={"min_price": 30})) == []

        # Same thing the app does at startup (ensure_indexes); run on the app's own event loop.
        assert client.portal.call(repo.backfill_price_ranges, _app_db()) == 1
        assert names(client.get("/places", params={"min_price": 30})) == ["old"]
        assert client.portal.call(repo.backfill_price_ranges, _app_db()) == 0  # idempotent


def _app_db():
    from app.db import get_db

    return get_db()


class TestOpeningStatusInSummary:
    @pytest.fixture(autouse=True)
    def office(self, client, minimal_payload):
        add_place(client, minimal_payload, "office", RYNEK, opening_hours=OFFICE_HOURS)
        add_place(client, minimal_payload, "nonstop", RYNEK, opening_hours={"always_open": True})
        add_place(client, minimal_payload, "unknown", RYNEK)

    def summaries(self, client, monkeypatch, moment) -> dict[str, dict]:
        monkeypatch.setattr(places_router, "local_now", lambda: moment)
        return {s["name"]: s for s in client.get("/places/summary").json()}

    def test_open_with_closing_time(self, client, monkeypatch):
        office = self.summaries(client, monkeypatch, WEDNESDAY_AFTERNOON)["office"]
        assert office["open_now"] is True
        assert office["closes_at"] == "2026-10-07T18:00:00+02:00"
        assert office["opens_at"] is None

    def test_closed_with_next_opening(self, client, monkeypatch):
        office = self.summaries(client, monkeypatch, WEDNESDAY_NIGHT)["office"]
        assert office["open_now"] is False
        assert office["opens_at"] == "2026-10-08T08:00:00+02:00"
        assert office["closes_at"] is None

    def test_nonstop_and_unknown(self, client, monkeypatch):
        by_name = self.summaries(client, monkeypatch, WEDNESDAY_NIGHT)
        assert (by_name["nonstop"]["open_now"], by_name["nonstop"]["closes_at"]) == (True, None)
        assert (by_name["unknown"]["open_now"], by_name["unknown"]["closes_at"], by_name["unknown"]["opens_at"]) == (
            None, None, None,
        )
