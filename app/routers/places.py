from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, status
from pymongo.asynchronous.database import AsyncDatabase

from app.db import get_db
from app.models.place import Coordinates, Place, PlaceCreate
from app.repositories import places as repo

router = APIRouter(prefix="/places", tags=["places"])

Db = Annotated[AsyncDatabase, Depends(get_db)]


@router.post("", status_code=status.HTTP_201_CREATED)
async def create_place(place: PlaceCreate, db: Db) -> Place:
    try:
        return await repo.create_place(db, place)
    except repo.PlaceAlreadyExists:
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            f"Place linked to OSM {place.osm.type}/{place.osm.id} already exists",
        )


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
