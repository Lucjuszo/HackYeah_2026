from datetime import datetime

from pydantic import BaseModel, Field

from app.models.place import RatingSummary


class RatingCreate(BaseModel):
    score: int = Field(ge=1, le=5)


class Rating(BaseModel):
    place_id: str
    user_id: str
    score: int
    created_at: datetime
    updated_at: datetime


class RatingResult(BaseModel):
    """The user's rating together with the place's recalculated summary."""

    rating: Rating
    summary: RatingSummary
