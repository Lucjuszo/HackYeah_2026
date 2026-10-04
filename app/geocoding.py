"""City / address search for the frontend's location picker, via OpenStreetMap Nominatim.

The frontend never calls Nominatim directly: browsers can't send the identifying User-Agent the
public instance requires, and many users would quickly exceed its limit of 1 request per second.
Here all requests share one client, are spaced at least a second apart and cached, so typing
"Krak" ... "Kraków" or many users searching for the same city costs one upstream request.
"""

import asyncio
import time
from collections import OrderedDict

import httpx
from pydantic import BaseModel, Field

from app.config import settings

MIN_INTERVAL_S = 1.0  # Nominatim usage policy
CACHE_TTL_S = 24 * 3600
CACHE_SIZE = 1000


class GeocodingUnavailable(Exception):
    pass


class GeocodeResult(BaseModel):
    name: str = Field(description="Short label, e.g. 'Kraków' or 'Floriańska 15'")
    display_name: str = Field(description="Full address from OpenStreetMap")
    lat: float
    lon: float
    kind: str = Field(description="OSM type, e.g. 'city', 'suburb', 'house'")
    # [south, north, west, east] – lets the frontend zoom to a whole city instead of a point.
    bbox: list[float] | None = None


class ReverseGeocodeResult(BaseModel):
    """Address of a point, shaped like a place's `address` (ready for POST /places)."""

    street: str | None = None
    house_number: str | None = None
    postcode: str | None = None
    city: str | None = Field(None, description="City, town or village; None in the middle of nowhere")
    country_code: str | None = Field(None, description="ISO 3166-1 alpha-2, lowercase")
    display_name: str


def _reverse_result(item: dict) -> ReverseGeocodeResult:
    address = item.get("address", {})
    city = next(
        (address[k] for k in ("city", "town", "village", "municipality", "hamlet", "county") if address.get(k)),
        None,
    )
    return ReverseGeocodeResult(
        street=address.get("road") or address.get("pedestrian") or address.get("square"),
        house_number=address.get("house_number"),
        postcode=address.get("postcode"),
        city=city,
        country_code=(address.get("country_code") or "").lower() or None,
        display_name=item.get("display_name", ""),
    )


def _result(item: dict) -> GeocodeResult:
    bbox = item.get("boundingbox")
    return GeocodeResult(
        name=item.get("name") or item["display_name"].split(",")[0],
        display_name=item["display_name"],
        lat=float(item["lat"]),
        lon=float(item["lon"]),
        kind=item.get("addresstype") or item.get("type") or "place",
        bbox=[float(v) for v in bbox] if bbox and len(bbox) == 4 else None,
    )


class Geocoder:
    def __init__(self, transport: httpx.AsyncBaseTransport | None = None) -> None:
        self._transport = transport
        self._client: httpx.AsyncClient | None = None
        self._lock = asyncio.Lock()
        self._last_request = 0.0
        self._cache: OrderedDict[tuple, tuple[float, object]] = OrderedDict()

    def _http(self) -> httpx.AsyncClient:
        # Created lazily: it must belong to the event loop that serves requests.
        if self._client is None:
            self._client = httpx.AsyncClient(
                base_url=settings.nominatim_url,
                headers={"User-Agent": settings.geocoding_user_agent, "Accept-Language": "pl"},
                timeout=10,
                transport=self._transport,
            )
        return self._client

    async def aclose(self) -> None:
        if self._client is not None:
            await self._client.aclose()
            self._client = None

    def clear_cache(self) -> None:
        self._cache.clear()

    async def _cached(self, key: tuple, path: str, params: dict, parse):
        """GET from Nominatim through the cache, one upstream request at a time spaced by MIN_INTERVAL_S."""
        if (hit := self._cache.get(key)) and hit[0] > time.monotonic():
            self._cache.move_to_end(key)
            return hit[1]

        async with self._lock:
            if (hit := self._cache.get(key)) and hit[0] > time.monotonic():  # filled while we waited
                return hit[1]
            wait = self._last_request + MIN_INTERVAL_S - time.monotonic()
            if wait > 0:
                await asyncio.sleep(wait)
            try:
                response = await self._http().get(path, params={"format": "jsonv2", **params})
            except httpx.HTTPError as e:
                raise GeocodingUnavailable(str(e)) from e
            finally:
                self._last_request = time.monotonic()
            if response.status_code != 200:
                raise GeocodingUnavailable(f"Nominatim answered HTTP {response.status_code}")
            result = parse(response.json())

        self._cache[key] = (time.monotonic() + CACHE_TTL_S, result)
        while len(self._cache) > CACHE_SIZE:
            self._cache.popitem(last=False)
        return result

    async def search(self, query: str, limit: int = 5) -> list[GeocodeResult]:
        params: dict = {"q": query, "limit": limit, "addressdetails": 0}
        if settings.geocoding_countries:
            params["countrycodes"] = settings.geocoding_countries
        return await self._cached(
            ("search", " ".join(query.lower().split()), limit),
            "/search",
            params,
            lambda body: [_result(item) for item in body],
        )

    async def reverse(self, lat: float, lon: float) -> ReverseGeocodeResult | None:
        """None where Nominatim knows no address (sea, wilderness)."""
        # ~1 m precision for the cache key: the same pin dropped twice costs one upstream request.
        return await self._cached(
            ("reverse", round(lat, 5), round(lon, 5)),
            "/reverse",
            {"lat": lat, "lon": lon, "zoom": 18, "addressdetails": 1},
            lambda body: None if "error" in body else _reverse_result(body),
        )

geocoder = Geocoder()
