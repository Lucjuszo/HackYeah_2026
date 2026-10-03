from fastapi import APIRouter, HTTPException, status

from app.auth import CurrentUser
from app.models.place import RatingSummary
from app.models.rating import Rating, RatingCreate, RatingResult
from app.repositories import ratings as repo
from app.routers.deps import Db, ExistingPlaceId

router = APIRouter(prefix="/places/{place_id}/ratings", tags=["ratings"])


@router.get("")
async def get_rating_summary(place_id: ExistingPlaceId, db: Db) -> RatingSummary:
    return await repo.get_summary(db, place_id)


@router.get("/me")
async def get_my_rating(place_id: ExistingPlaceId, db: Db, user: CurrentUser) -> Rating:
    rating = await repo.get_rating(db, place_id, user.id)
    if rating is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "You haven't rated this place")
    return rating


@router.put("/me")
async def set_my_rating(place_id: ExistingPlaceId, body: RatingCreate, db: Db, user: CurrentUser) -> RatingResult:
    """Creates or replaces the current user's rating; one rating per user per place."""
    rating, summary = await repo.set_rating(db, place_id, user.id, body.score)
    return RatingResult(rating=rating, summary=summary)


@router.delete("/me")
async def delete_my_rating(place_id: ExistingPlaceId, db: Db, user: CurrentUser) -> RatingSummary:
    summary = await repo.delete_rating(db, place_id, user.id)
    if summary is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "You haven't rated this place")
    return summary
