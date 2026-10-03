from typing import Annotated

from fastapi import APIRouter, HTTPException, Query, Response, status

from app.geocoding import GeocodeResult, GeocodingUnavailable, ReverseGeocodeResult, geocoder

router = APIRouter(prefix="/geocode", tags=["geocoding"])


@router.get("")
async def geocode(
    response: Response,
    q: Annotated[str, Query(min_length=2, max_length=200, description="City, district or address")],
    limit: Annotated[int, Query(ge=1, le=10)] = 5,
) -> list[GeocodeResult]:
    """Places in Poland matching `q` (OpenStreetMap Nominatim), for picking where to search. No login needed.

    Map data © OpenStreetMap contributors, ODbL.
    """
    try:
        results = await geocoder.search(q.strip(), limit)
    except GeocodingUnavailable:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "Address search is unavailable, try again later")
    response.headers["Cache-Control"] = "public, max-age=86400"
    return results


@router.get("/reverse")
async def reverse_geocode(
    response: Response,
    lat: Annotated[float, Query(ge=-90, le=90)],
    lon: Annotated[float, Query(ge=-180, le=180)],
) -> ReverseGeocodeResult:
    """Address of a point (e.g. where a new place is being added). 404 where there is no address. No login needed."""
    try:
        result = await geocoder.reverse(lat, lon)
    except GeocodingUnavailable:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "Address search is unavailable, try again later")
    if result is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "No address at this point")
    response.headers["Cache-Control"] = "public, max-age=86400"
    return result
