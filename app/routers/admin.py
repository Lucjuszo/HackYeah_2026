from typing import Annotated

from fastapi import APIRouter, HTTPException, Query, Response, status

from app.auth import AdminUser
from app.models.place import Place, PlaceApproval, PlaceSort
from app.repositories import places as repo
from app.routers.deps import Db
from app.routers.places import TOTAL_HEADER

router = APIRouter(prefix="/admin", tags=["admin"])


@router.get("/places")
async def list_places_for_review(
    db: Db,
    _: AdminUser,
    response: Response,
    approved: Annotated[bool, Query(description="false = waiting for approval, true = public")] = False,
    q: Annotated[str | None, Query(min_length=1, max_length=100, description="Part of the name or street")] = None,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
    skip: Annotated[int, Query(ge=0)] = 0,
) -> list[Place]:
    """Admin only. Newest first; total in the `X-Total-Count` header."""
    f = repo.PlaceFilter(approved=approved, q=q)
    docs, total = await repo.search_places(db, f, sort=PlaceSort.NEWEST, limit=limit, skip=skip)
    response.headers[TOTAL_HEADER] = str(total)
    return [repo.from_document(doc) for doc in docs]


@router.put("/places/{place_id}/approval")
async def set_place_approval(place_id: str, body: PlaceApproval, db: Db, user: AdminUser) -> Place:
    """Admin only. `approved: true` publishes the place, `false` hides it again. Reject = DELETE /places/{id}."""
    place = await repo.set_approval(db, place_id, body.approved, user.id)
    if place is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Place not found")
    return place
