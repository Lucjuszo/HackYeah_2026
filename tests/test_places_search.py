from datetime import datetime
from zoneinfo import ZoneInfo

import pytest
from bson import ObjectId

from app.routers import places as places_router
from tests.helpers import as_admin, as_user, make_image
from tests.test_places_api import NEAR_200M, NEAR_800M, RYNEK, WARSAW, add_place

# Wednesday 2026-10-07, 14:30 in Kraków.
WEDNESDAY_AFTERNOON = datetime(2026, 10, 7, 14, 30, tzinfo=ZoneInfo("Europe/Warsaw"))
WEDNESDAY_NIGHT = datetime(2026, 10, 7, 23, 0, tzinfo=ZoneInfo("Europe/Warsaw"))
OFFICE_HOURS = {"periods": [{"day": d, "open": "08:00", "close": "18:00"} for d in range(5)]}


def names(response) -> list[str]:
    assert response.status_code == 200, response.text
    return [p["name"] for p in response.json()]


def rate(client, place_id, score, user):
    assert client.put(f"/places/{place_id}/ratings/me", json={"score": score}, headers=as_user(user)).status_code == 200


@pytest.fixture
def at(monkeypatch):
    """Freezes "now" for open_now / open_now filters."""

    def freeze(moment: datetime) -> None:
        monkeypatch.setattr(places_router, "local_now", lambda: moment)

    return freeze


class TestDistanceAndTotal:
    def test_distance_returned_only_for_near_searches(self, client, minimal_payload):
        add_place(client, minimal_payload, "close", NEAR_200M)
        add_place(client, minimal_payload, "far", NEAR_800M)

        places = client.get("/places", params={**RYNEK, "radius_m": 1000}).json()
        assert [p["name"] for p in places] == ["close", "far"]
        assert 150 < places[0]["distance_m"] < 300
        assert 700 < places[1]["distance_m"] < 900

        assert all(p["distance_m"] is None for p in client.get("/places").json())

    def test_total_count_header(self, client, minimal_payload):
        for i in range(5):
            add_place(client, minimal_payload, f"p{i}", RYNEK)
        add_place(client, minimal_payload, "warsaw", WARSAW)

        response = client.get("/places", params={"limit": 2})
        assert len(response.json()) == 2
        assert response.headers["X-Total-Count"] == "6"

        response = client.get("/places", params={**RYNEK, "radius_m": 1000, "limit": 2})
        assert response.headers["X-Total-Count"] == "5"

    def test_total_count_with_filters(self, client, minimal_payload):
        add_place(client, minimal_payload, "wifi", RYNEK, amenities={"wifi": True})
        add_place(client, minimal_payload, "no wifi", RYNEK, amenities={"wifi": False})
        assert client.get("/places", params={"wifi": "true"}).headers["X-Total-Count"] == "1"


class TestFilters:
    def test_wifi(self, client, minimal_payload):
        add_place(client, minimal_payload, "yes", RYNEK, amenities={"wifi": True})
        add_place(client, minimal_payload, "no", RYNEK, amenities={"wifi": False})
        add_place(client, minimal_payload, "unknown", RYNEK)
        assert names(client.get("/places", params={"wifi": "true"})) == ["yes"]
        assert names(client.get("/places", params={"wifi": "false"})) == ["no"]

    def test_atmosphere(self, client, minimal_payload):
        add_place(client, minimal_payload, "library", RYNEK, atmosphere="quiet")
        add_place(client, minimal_payload, "pub", RYNEK, atmosphere="lively")
        assert names(client.get("/places", params={"atmosphere": "quiet"})) == ["library"]
        assert client.get("/places", params={"atmosphere": "loud"}).status_code == 422

    @pytest.mark.parametrize(("q", "expected"), [("kaw", ["Kawiarnia Pod Kodem"]), ("FLORIA", ["Kawiarnia Pod Kodem"])])
    def test_text_search_in_name_and_street(self, client, minimal_payload, q, expected):
        add_place(client, minimal_payload, "Kawiarnia Pod Kodem", RYNEK, address={
            "street": "Floriańska", "city": "Kraków", "country_code": "pl",
        })
        add_place(client, minimal_payload, "Biblioteka", RYNEK)
        assert names(client.get("/places", params={"q": q})) == expected

    def test_text_search_is_literal(self, client, minimal_payload):
        add_place(client, minimal_payload, "Cafe (24h)", RYNEK)
        add_place(client, minimal_payload, "Cafe 24h", RYNEK)
        assert names(client.get("/places", params={"q": "(24h)"})) == ["Cafe (24h)"]
        assert names(client.get("/places", params={"q": ".*"})) == []

    def test_min_rating(self, client, minimal_payload):
        good = add_place(client, minimal_payload, "good", RYNEK)
        bad = add_place(client, minimal_payload, "bad", RYNEK)
        add_place(client, minimal_payload, "unrated", RYNEK)
        rate(client, good["id"], 5, "anna")
        rate(client, bad["id"], 2, "anna")
        assert names(client.get("/places", params={"min_rating": 4})) == ["good"]

    def test_open_now(self, client, minimal_payload, at):
        add_place(client, minimal_payload, "office", RYNEK, opening_hours=OFFICE_HOURS)
        add_place(client, minimal_payload, "nonstop", RYNEK, opening_hours={"always_open": True})
        add_place(client, minimal_payload, "unknown", RYNEK)

        at(WEDNESDAY_AFTERNOON)
        assert names(client.get("/places", params={"open_now": "true", "sort": "name"})) == ["nonstop", "office"]
        at(WEDNESDAY_NIGHT)
        assert names(client.get("/places", params={"open_now": "true"})) == ["nonstop"]

    def test_filters_combine_with_near(self, client, minimal_payload):
        add_place(client, minimal_payload, "close wifi", NEAR_200M, amenities={"wifi": True})
        add_place(client, minimal_payload, "close", NEAR_200M)
        add_place(client, minimal_payload, "warsaw wifi", WARSAW, amenities={"wifi": True})
        assert names(client.get("/places", params={**RYNEK, "wifi": "true"})) == ["close wifi"]

    def test_text_search_and_open_now_together(self, client, minimal_payload, at):
        add_place(client, minimal_payload, "Kawa nocna", RYNEK, opening_hours={"always_open": True})
        add_place(client, minimal_payload, "Kawa dzienna", RYNEK, opening_hours=OFFICE_HOURS)
        at(WEDNESDAY_NIGHT)
        assert names(client.get("/places", params={"q": "kawa", "open_now": "true"})) == ["Kawa nocna"]


class TestSort:
    def test_by_rating_unrated_last(self, client, minimal_payload):
        places = {n: add_place(client, minimal_payload, n, RYNEK) for n in ("ok", "unrated", "best")}
        rate(client, places["ok"]["id"], 3, "anna")
        rate(client, places["best"]["id"], 5, "anna")
        assert names(client.get("/places", params={"sort": "rating"})) == ["best", "ok", "unrated"]

    def test_by_name_newest_oldest(self, client, minimal_payload):
        for n in ("b", "c", "a"):
            add_place(client, minimal_payload, n, RYNEK)
        assert names(client.get("/places", params={"sort": "name"})) == ["a", "b", "c"]
        assert names(client.get("/places", params={"sort": "newest"})) == ["a", "c", "b"]
        assert names(client.get("/places", params={"sort": "oldest"})) == ["b", "c", "a"]
        assert names(client.get("/places")) == ["b", "c", "a"]  # default without lat/lon

    def test_near_with_other_sort(self, client, minimal_payload):
        far = add_place(client, minimal_payload, "far", NEAR_800M)
        add_place(client, minimal_payload, "close", NEAR_200M)
        rate(client, far["id"], 5, "anna")
        response = client.get("/places", params={**RYNEK, "sort": "rating"})
        assert names(response) == ["far", "close"]
        assert response.json()[0]["distance_m"] > 700

    def test_distance_without_point_rejected(self, client):
        assert client.get("/places", params={"sort": "distance"}).status_code == 422

    def test_unknown_sort_rejected(self, client):
        assert client.get("/places", params={"sort": "random"}).status_code == 422


class TestSummary:
    def test_light_records(self, client, place_payload, at):
        place = client.post("/places", json=place_payload).json()
        photo = client.post(
            f"/places/{place['id']}/photos", files={"file": ("p.jpg", make_image(), "image/jpeg")}
        ).json()
        at(WEDNESDAY_AFTERNOON)

        response = client.get("/places/summary")
        assert response.status_code == 200
        assert response.headers["X-Total-Count"] == "1"
        [summary] = response.json()
        assert summary["id"] == place["id"]
        assert summary["name"] == place["name"]
        assert summary["coordinates"] == place["coordinates"]
        assert summary["thumbnail_url"] == photo["thumbnail"]["url"]
        assert summary["photo_count"] == 1
        assert summary["rating"] == {"average": None, "count": 0}
        assert isinstance(summary["open_now"], bool)
        assert "menu" not in summary and "opening_hours" not in summary

    def test_open_now_flag(self, client, minimal_payload, at):
        add_place(client, minimal_payload, "office", RYNEK, opening_hours=OFFICE_HOURS)
        add_place(client, minimal_payload, "unknown", RYNEK)
        at(WEDNESDAY_NIGHT)
        flags = {s["name"]: s["open_now"] for s in client.get("/places/summary").json()}
        assert flags == {"office": False, "unknown": None}
        at(WEDNESDAY_AFTERNOON)
        flags = {s["name"]: s["open_now"] for s in client.get("/places/summary").json()}
        assert flags == {"office": True, "unknown": None}

    def test_same_filters_and_distance(self, client, minimal_payload):
        add_place(client, minimal_payload, "far", NEAR_800M, amenities={"wifi": True})
        add_place(client, minimal_payload, "close", NEAR_200M, amenities={"wifi": True})
        add_place(client, minimal_payload, "no wifi", NEAR_200M)
        summaries = client.get("/places/summary", params={**RYNEK, "wifi": "true"}).json()
        assert [s["name"] for s in summaries] == ["close", "far"]
        assert summaries[0]["distance_m"] < summaries[1]["distance_m"]

    def test_without_photos(self, client, minimal_payload):
        add_place(client, minimal_payload, "bare", RYNEK)
        [summary] = client.get("/places/summary").json()
        assert summary["thumbnail_url"] is None
        assert summary["photo_count"] == 0

    def test_limit(self, client):
        assert client.get("/places/summary", params={"limit": 1000}).status_code == 200
        assert client.get("/places/summary", params={"limit": 1001}).status_code == 422


class TestDeletePlace:
    def test_admin_deletes_place_with_everything(self, client, created_place, db):
        place_id = created_place["id"]
        photo = client.post(f"/places/{place_id}/photos", files={"file": ("p.jpg", make_image(), "image/jpeg")}).json()
        rate(client, place_id, 4, "anna")
        client.post(f"/places/{place_id}/comments", json={"text": "Super", "score": 4})

        assert client.delete(f"/places/{place_id}", headers=as_admin()).status_code == 204
        assert client.get(f"/places/{place_id}").status_code == 404
        assert client.get(photo["url"]).status_code == 404
        assert client.get(photo["thumbnail"]["url"]).status_code == 404
        assert db.ratings.count_documents({"place_id": ObjectId(place_id)}) == 0
        assert db.comments.count_documents({"place_id": ObjectId(place_id)}) == 0

    def test_other_places_untouched(self, client, created_place, minimal_payload, db):
        other = add_place(client, minimal_payload, "other", RYNEK)
        rate(client, other["id"], 5, "anna")
        client.delete(f"/places/{created_place['id']}", headers=as_admin())
        assert client.get(f"/places/{other['id']}").status_code == 200
        assert db.ratings.count_documents({}) == 1

    def test_regular_user_forbidden(self, client, created_place):
        assert client.delete(f"/places/{created_place['id']}").status_code == 403
        assert client.get(f"/places/{created_place['id']}").status_code == 200

    @pytest.mark.parametrize("place_id", [str(ObjectId()), "not-an-id"])
    def test_unknown(self, client, place_id):
        assert client.delete(f"/places/{place_id}", headers=as_admin()).status_code == 404


GDANSK = {"lat": 54.3520, "lon": 18.6466}
ZAKOPANE = {"lat": 49.2992, "lon": 19.9496}
KRAKOW_BBOX = "49.96,19.79,50.13,20.22"
POLAND_BBOX = "49.0,14.1,54.9,24.2"


class TestBoundingBox:
    @pytest.fixture(autouse=True)
    def places_across_poland(self, client, minimal_payload):
        add_place(client, minimal_payload, "rynek", RYNEK)
        add_place(client, minimal_payload, "nowa huta", {"lat": 50.0720, "lon": 20.0378})
        add_place(client, minimal_payload, "zakopane", ZAKOPANE)
        add_place(client, minimal_payload, "gdansk", GDANSK)
        add_place(client, minimal_payload, "warsaw", WARSAW)

    def test_city_viewport(self, client):
        response = client.get("/places/summary", params={"bbox": KRAKOW_BBOX, "sort": "name"})
        assert names(response) == ["nowa huta", "rynek"]
        assert response.headers["X-Total-Count"] == "2"
        assert all(p["distance_m"] is None for p in response.json())

    def test_whole_country_beyond_50_km(self, client):
        response = client.get("/places", params={"bbox": POLAND_BBOX, "sort": "name"})
        assert names(response) == ["gdansk", "nowa huta", "rynek", "warsaw", "zakopane"]

    def test_combines_with_filters(self, client, minimal_payload):
        add_place(client, minimal_payload, "rynek wifi", RYNEK, amenities={"wifi": True})
        response = client.get("/places", params={"bbox": KRAKOW_BBOX, "wifi": "true"})
        assert names(response) == ["rynek wifi"]

    def test_with_lat_lon_rejected(self, client):
        assert client.get("/places", params={"bbox": KRAKOW_BBOX, **RYNEK}).status_code == 422

    @pytest.mark.parametrize(
        "bbox",
        ["1,2,3", "a,b,c,d", "50,19,49,20", "49,20,50,19", "-91,0,0,10", "0,-170,10,170", "49,19,50,181"],
    )
    def test_invalid(self, client, bbox):
        response = client.get("/places", params={"bbox": bbox})
        assert response.status_code == 422
        assert "bbox" in response.text

    def test_distance_sort_needs_point(self, client):
        assert client.get("/places", params={"bbox": KRAKOW_BBOX, "sort": "distance"}).status_code == 422
