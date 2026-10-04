import time

import httpx
import pytest

from app import geocoding
from app.config import settings
from app.routers import geocode as geocode_router
from tests.helpers import ANONYMOUS

KRAKOW = {
    "name": "Kraków",
    "display_name": "Kraków, województwo małopolskie, Polska",
    "lat": "50.0619474",
    "lon": "19.9368564",
    "addresstype": "city",
    "boundingbox": ["49.9676668", "50.1261338", "19.7922355", "20.2173455"],
}
FLORIANSKA = {
    "name": "",
    "display_name": "15, Floriańska, Stare Miasto, Kraków, Polska",
    "lat": "50.0633",
    "lon": "19.9396",
    "type": "house",
}


class FakeNominatim:
    def __init__(self, results=None, status_code=200, error: Exception | None = None):
        self.results = [KRAKOW] if results is None else results
        self.status_code = status_code
        self.error = error
        self.requests: list[httpx.Request] = []
        self.times: list[float] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        self.times.append(time.monotonic())
        if self.error:
            raise self.error
        return httpx.Response(self.status_code, json=self.results)


@pytest.fixture
def nominatim(monkeypatch):
    def install(fake: FakeNominatim, interval: float = 0.0) -> FakeNominatim:
        monkeypatch.setattr(geocoding, "MIN_INTERVAL_S", interval)
        monkeypatch.setattr(geocode_router, "geocoder", geocoding.Geocoder(transport=httpx.MockTransport(fake)))
        return fake

    return install


def test_search(client, nominatim):
    fake = nominatim(FakeNominatim())
    response = client.get("/geocode", params={"q": "Kraków"}, headers=ANONYMOUS)
    assert response.status_code == 200
    assert response.json() == [
        {
            "name": "Kraków",
            "display_name": "Kraków, województwo małopolskie, Polska",
            "lat": 50.0619474,
            "lon": 19.9368564,
            "kind": "city",
            "bbox": [49.9676668, 50.1261338, 19.7922355, 20.2173455],
        }
    ]
    assert response.headers["Cache-Control"] == "public, max-age=86400"

    [request] = fake.requests
    assert request.url.path == "/search"
    assert request.url.params["q"] == "Kraków"
    assert request.url.params["countrycodes"] == "pl"
    assert request.url.params["format"] == "jsonv2"
    assert request.headers["User-Agent"] == settings.geocoding_user_agent
    assert request.headers["Accept-Language"] == "pl"


def test_address_without_name_and_bbox(client, nominatim):
    nominatim(FakeNominatim([FLORIANSKA]))
    [result] = client.get("/geocode", params={"q": "Floriańska 15"}).json()
    assert result["name"] == "15"
    assert result["kind"] == "house"
    assert result["bbox"] is None


def test_cached_case_and_whitespace_insensitive(client, nominatim):
    fake = nominatim(FakeNominatim())
    for q in ("Kraków", "kraków", "  KRAKÓW "):
        assert client.get("/geocode", params={"q": q}).status_code == 200
    assert len(fake.requests) == 1


def test_different_limit_is_a_different_query(client, nominatim):
    fake = nominatim(FakeNominatim())
    client.get("/geocode", params={"q": "Kraków", "limit": 1})
    client.get("/geocode", params={"q": "Kraków", "limit": 5})
    assert [r.url.params["limit"] for r in fake.requests] == ["1", "5"]


def test_upstream_requests_are_spaced(client, nominatim):
    fake = nominatim(FakeNominatim(), interval=0.3)
    for q in ("Gdańsk", "Sopot", "Gdynia"):
        client.get("/geocode", params={"q": q})
    gaps = [b - a for a, b in zip(fake.times, fake.times[1:])]
    assert len(gaps) == 2
    assert all(gap >= 0.29 for gap in gaps)


def test_no_results(client, nominatim):
    nominatim(FakeNominatim([]))
    assert client.get("/geocode", params={"q": "Nieistniejąca wieś"}).json() == []


@pytest.mark.parametrize(
    "fake", [FakeNominatim(status_code=429), FakeNominatim(error=httpx.ConnectTimeout("timeout"))]
)
def test_upstream_failure_is_503_and_not_cached(client, nominatim, fake):
    nominatim(fake)
    assert client.get("/geocode", params={"q": "Kraków"}).status_code == 503
    fake.status_code, fake.error = 200, None
    assert client.get("/geocode", params={"q": "Kraków"}).status_code == 200


def test_all_countries_when_configured(client, nominatim, monkeypatch):
    monkeypatch.setattr(settings, "geocoding_countries", "")
    fake = nominatim(FakeNominatim())
    client.get("/geocode", params={"q": "Berlin"})
    assert "countrycodes" not in fake.requests[0].url.params


@pytest.mark.parametrize("params", [{}, {"q": "K"}, {"q": "x" * 201}, {"q": "Kraków", "limit": 11}])
def test_validation(client, params):
    assert client.get("/geocode", params=params).status_code == 422


FLORIANSKA_REVERSE = {
    "display_name": "15, Floriańska, Stare Miasto, Kraków, małopolskie, 31-019, Polska",
    "address": {
        "house_number": "15",
        "road": "Floriańska",
        "suburb": "Stare Miasto",
        "city": "Kraków",
        "postcode": "31-019",
        "country_code": "PL",
    },
}


class FakeReverse(FakeNominatim):
    def __call__(self, request):
        super().__call__(request)
        return httpx.Response(self.status_code, json=self.results)


class TestReverse:
    def test_address_of_a_point(self, client, nominatim):
        fake = nominatim(FakeReverse(FLORIANSKA_REVERSE))
        response = client.get("/geocode/reverse", params={"lat": 50.0633, "lon": 19.9396}, headers=ANONYMOUS)
        assert response.status_code == 200
        assert response.json() == {
            "street": "Floriańska",
            "house_number": "15",
            "postcode": "31-019",
            "city": "Kraków",
            "country_code": "pl",
            "display_name": FLORIANSKA_REVERSE["display_name"],
        }
        [request] = fake.requests
        assert request.url.path == "/reverse"
        assert request.url.params["addressdetails"] == "1"

    def test_village_counts_as_city(self, client, nominatim):
        nominatim(FakeReverse({"display_name": "x", "address": {"village": "Zawoja", "country_code": "pl"}}))
        body = client.get("/geocode/reverse", params={"lat": 49.6, "lon": 19.5}).json()
        assert (body["city"], body["street"]) == ("Zawoja", None)

    def test_nowhere_is_404(self, client, nominatim):
        nominatim(FakeReverse({"error": "Unable to geocode"}))
        assert client.get("/geocode/reverse", params={"lat": 55.5, "lon": 17.0}).status_code == 404

    def test_cached_per_point(self, client, nominatim):
        fake = nominatim(FakeReverse(FLORIANSKA_REVERSE))
        client.get("/geocode/reverse", params={"lat": 50.063301, "lon": 19.939601})
        client.get("/geocode/reverse", params={"lat": 50.063302, "lon": 19.939602})  # same ~1 m cell
        assert len(fake.requests) == 1

    def test_upstream_failure(self, client, nominatim):
        nominatim(FakeReverse(status_code=500))
        assert client.get("/geocode/reverse", params={"lat": 50.0, "lon": 19.0}).status_code == 503

    @pytest.mark.parametrize("params", [{}, {"lat": 91, "lon": 0}, {"lat": 50, "lon": 181}])
    def test_validation(self, client, params):
        assert client.get("/geocode/reverse", params=params).status_code == 422
