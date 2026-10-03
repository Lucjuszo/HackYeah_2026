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
        self._cache: OrderedDict[tuple[str, int], tuple[float, list[GeocodeResult]]] = OrderedDict()

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

    async def search(self, query: str, limit: int = 5) -> list[GeocodeResult]:
        key = (" ".join(query.lower().split()), limit)
        if (hit := self._cache.get(key)) and hit[0] > time.monotonic():
            self._cache.move_to_end(key)
            return hit[1]

        async with self._lock:  # one upstream request at a time, spaced by MIN_INTERVAL_S
            if (hit := self._cache.get(key)) and hit[0] > time.monotonic():  # filled while we waited
                return hit[1]
            wait = self._last_request + MIN_INTERVAL_S - time.monotonic()
            if wait > 0:
                await asyncio.sleep(wait)
            params = {"q": query, "format": "jsonv2", "limit": limit, "addressdetails": 0}
            if settings.geocoding_countries:
                params["countrycodes"] = settings.geocoding_countries
            try:
                response = await self._http().get("/search", params=params)
            except httpx.HTTPError as e:
                raise GeocodingUnavailable(str(e)) from e
            finally:
                self._last_request = time.monotonic()
            if response.status_code != 200:
                raise GeocodingUnavailable(f"Nominatim answered HTTP {response.status_code}")
            results = [_result(item) for item in response.json()]

        self._cache[key] = (time.monotonic() + CACHE_TTL_S, results)
        while len(self._cache) > CACHE_SIZE:
            self._cache.popitem(last=False)
        return results


geocoder = Geocoder()
