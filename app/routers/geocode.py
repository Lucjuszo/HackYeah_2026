from typing import Annotated

from fastapi import APIRouter, HTTPException, Query, Response, status

from app.geocoding import GeocodeResult, GeocodingUnavailable, geocoder

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
