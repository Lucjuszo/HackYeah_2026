from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status

from app.auth import CurrentUser
from app.db import local_now
from app.models.place import Atmosphere, Coordinates, OsmRef, Place, PlaceCreate, PlaceSort, PlaceSummary, PlaceUpdate
from app.repositories import places as repo
from app.routers.deps import Db
from app.storage import get_storage

router = APIRouter(prefix="/places", tags=["places"])

TOTAL_HEADER = "X-Total-Count"


def _osm_conflict(osm: OsmRef) -> HTTPException:
    return HTTPException(status.HTTP_409_CONFLICT, f"Place linked to OSM {osm.type}/{osm.id} already exists")


def _parse_bbox(value: str) -> repo.BoundingBox:
    def invalid(reason: str) -> HTTPException:
        return HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, f"bbox must be 'south,west,north,east': {reason}")

    try:
        south, west, north, east = (float(part) for part in value.split(","))
    except ValueError:
        raise invalid("four numbers expected")
    if not (-90 <= south < north <= 90):
        raise invalid("need -90 <= south < north <= 90")
    if not (-180 <= west < east <= 180):
        raise invalid("need -180 <= west < east <= 180")
    if east - west > 180:  # a polygon wider than half the globe would be read as its complement
        raise invalid("at most 180 degrees wide; omit bbox to search everywhere")
    return repo.BoundingBox(south=south, west=west, north=north, east=east)


def place_filter(
    lat: Annotated[float | None, Query(ge=-90, le=90)] = None,
    lon: Annotated[float | None, Query(ge=-180, le=180)] = None,
    radius_m: Annotated[int, Query(gt=0, le=50_000)] = 1000,
    bbox: Annotated[
        str | None,
        Query(
            description="Visible map area 'south,west,north,east' (degrees), any size; instead of lat/lon",
            examples=["49.96,19.79,50.13,20.22"],
        ),
    ] = None,
    q: Annotated[str | None, Query(min_length=1, max_length=100, description="Part of the name or street")] = None,
    wifi: bool | None = None,
    power_outlets: bool | None = None,
    atmosphere: Atmosphere | None = None,
    min_rating: Annotated[float | None, Query(ge=1, le=5)] = None,
    min_price: Annotated[int | None, Query(ge=0, description="PLN; price_range.min >= this")] = None,
    max_price: Annotated[
        int | None, Query(ge=0, description="PLN; price_range.max <= this (0 = free places only)")
    ] = None,
    open_now: Annotated[bool, Query(description="Only places open right now (unknown hours excluded)")] = False,
) -> repo.PlaceFilter:
    if (lat is None) != (lon is None):
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "Provide both lat and lon, or neither")
    box = _parse_bbox(bbox) if bbox is not None else None
    if box and lat is not None:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "Use either bbox or lat/lon, not both")
    if min_price is not None and max_price is not None and min_price > max_price:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "min_price cannot exceed max_price")
    return repo.PlaceFilter(
        near=Coordinates(lat=lat, lon=lon) if lat is not None else None,
        radius_m=radius_m,
        bbox=box,
        q=q,
        wifi=wifi,
        power_outlets=power_outlets,
        atmosphere=atmosphere,
        min_rating=min_rating,
        min_price=min_price,
        max_price=max_price,
        open_at=local_now() if open_now else None,
    )


Filter = Annotated[repo.PlaceFilter, Depends(place_filter)]
SortParam = Annotated[
    PlaceSort | None, Query(description="Default: distance with lat/lon, oldest first otherwise")
]


async def _search(db: Db, f: repo.PlaceFilter, sort: PlaceSort | None, limit: int, skip: int, response: Response):
    if sort == PlaceSort.DISTANCE and f.near is None:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "sort=distance needs lat and lon")
    docs, total = await repo.search_places(db, f, sort=sort, limit=limit, skip=skip)
    response.headers[TOTAL_HEADER] = str(total)
    return docs


@router.post("", status_code=status.HTTP_201_CREATED)
async def create_place(place: PlaceCreate, db: Db, user: CurrentUser) -> Place:
    try:
        return await repo.create_place(db, place, user.id)
    except repo.PlaceAlreadyExists:
        raise _osm_conflict(place.osm)


@router.get("")
async def list_places(
    db: Db,
    f: Filter,
    response: Response,
    sort: SortParam = None,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
    skip: Annotated[int, Query(ge=0)] = 0,
) -> list[Place]:
    """Full places. Total number of matches (for pagination) in the `X-Total-Count` header."""
    docs = await _search(db, f, sort, limit, skip, response)
    return [repo.from_document(doc) for doc in docs]


@router.get("/summary")
async def list_place_summaries(
    db: Db,
    f: Filter,
    response: Response,
    sort: SortParam = None,
    limit: Annotated[int, Query(ge=1, le=1000)] = 200,
    skip: Annotated[int, Query(ge=0)] = 0,
) -> list[PlaceSummary]:
    """Same search as GET /places, light records for map pins and list cards (+ `open_now`, thumbnail)."""
    docs = await _search(db, f, sort, limit, skip, response)
    now = local_now()
    return [repo.summary_from_document(doc, now) for doc in docs]


@router.get("/{place_id}")
async def get_place(place_id: str, db: Db) -> Place:
    place = await repo.get_place(db, place_id)
    if place is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Place not found")
    return place


@router.patch("/{place_id}")
async def update_place(place_id: str, update: PlaceUpdate, db: Db, user: CurrentUser) -> Place:
    """Any logged-in user can edit a place; the last editor is recorded in `updated_by`."""
    try:
        place = await repo.update_place(db, place_id, update, user.id)
    except repo.PlaceAlreadyExists:
        raise _osm_conflict(update.osm)
    if place is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Place not found")
    return place


@router.delete("/{place_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_place(place_id: str, db: Db, user: CurrentUser) -> None:
    """Admin only. Also deletes the place's ratings, comments and photo files."""
    if not user.is_admin:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Only an admin can delete places")
    keys = await repo.delete_place(db, place_id)
    if keys is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Place not found")
    storage = get_storage()
    for key in keys:
        await storage.delete(key)
