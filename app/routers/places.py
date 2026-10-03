from typing import Annotated

from fastapi import APIRouter, HTTPException, Query, status

from app.auth import CurrentUserId
from app.models.place import Coordinates, OsmRef, Place, PlaceCreate, PlaceUpdate
from app.repositories import places as repo
from app.routers.deps import Db

router = APIRouter(prefix="/places", tags=["places"])


def _osm_conflict(osm: OsmRef) -> HTTPException:
    return HTTPException(status.HTTP_409_CONFLICT, f"Place linked to OSM {osm.type}/{osm.id} already exists")


@router.post("", status_code=status.HTTP_201_CREATED)
async def create_place(place: PlaceCreate, db: Db, user_id: CurrentUserId) -> Place:
    try:
        return await repo.create_place(db, place, user_id)
    except repo.PlaceAlreadyExists:
        raise _osm_conflict(place.osm)


@router.get("")
async def list_places(
    db: Db,
    lat: Annotated[float | None, Query(ge=-90, le=90)] = None,
    lon: Annotated[float | None, Query(ge=-180, le=180)] = None,
    radius_m: Annotated[int, Query(gt=0, le=50_000)] = 1000,
    power_outlets: bool | None = None,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
    skip: Annotated[int, Query(ge=0)] = 0,
) -> list[Place]:
    if (lat is None) != (lon is None):
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "Provide both lat and lon, or neither")
    near = Coordinates(lat=lat, lon=lon) if lat is not None else None
    return await repo.list_places(
        db, near=near, radius_m=radius_m, power_outlets=power_outlets, limit=limit, skip=skip
    )


@router.get("/{place_id}")
async def get_place(place_id: str, db: Db) -> Place:
    place = await repo.get_place(db, place_id)
    if place is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Place not found")
    return place


@router.patch("/{place_id}")
async def update_place(place_id: str, update: PlaceUpdate, db: Db, user_id: CurrentUserId) -> Place:
    try:
        place = await repo.update_place(db, place_id, update, user_id)
    except repo.PlaceAlreadyExists:
        raise _osm_conflict(update.osm)
    if place is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Place not found")
    return place
