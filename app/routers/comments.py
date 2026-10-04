from typing import Annotated

from fastapi import APIRouter, HTTPException, Query, Response, status

from app.auth import CurrentUser
from app.config import settings
from app.models.comment import Comment, CommentCreate, CommentUpdate
from app.ratelimit import RateLimiter
from app.repositories import comments as repo
from app.routers.deps import Db, ExistingPlaceId

router = APIRouter(prefix="/places/{place_id}/comments", tags=["comments"])

comment_limiter = RateLimiter("comments", lambda: settings.comments_per_hour)


def _not_found() -> HTTPException:
    return HTTPException(status.HTTP_404_NOT_FOUND, "Comment not found")


def _forbidden() -> HTTPException:
    return HTTPException(status.HTTP_403_FORBIDDEN, "Only the author or an admin can change this comment")


@router.post("", status_code=status.HTTP_201_CREATED)
async def create_comment(place_id: ExistingPlaceId, body: CommentCreate, db: Db, user: CurrentUser) -> Comment:
    comment_limiter.check(user.id)
    return await repo.create_comment(db, place_id, user.id, body.text, user_name=user.name)


@router.get("")
async def list_comments(
    place_id: ExistingPlaceId,
    db: Db,
    response: Response,
    limit: Annotated[int, Query(ge=1, le=100)] = 20,
    skip: Annotated[int, Query(ge=0)] = 0,
) -> list[Comment]:
    """Total number of comments (for pagination) in the `X-Total-Count` header."""
    response.headers["X-Total-Count"] = str(await repo.count_comments(db, place_id))
    return await repo.list_comments(db, place_id, limit=limit, skip=skip)


@router.patch("/{comment_id}")
async def update_comment(
    place_id: ExistingPlaceId, comment_id: str, body: CommentUpdate, db: Db, user: CurrentUser
) -> Comment:
    """Author or admin only."""
    try:
        return await repo.update_comment(db, place_id, comment_id, body.text, user)
    except repo.CommentNotFound:
        raise _not_found()
    except repo.NotAllowed:
        raise _forbidden()


@router.put("/{comment_id}/like")
async def like_comment(place_id: ExistingPlaceId, comment_id: str, db: Db, user: CurrentUser) -> Comment:
    """Thumbs up from the current user (once per user; repeating it changes nothing)."""
    try:
        return await repo.set_like(db, place_id, comment_id, user.id, liked=True)
    except repo.CommentNotFound:
        raise _not_found()


@router.delete("/{comment_id}/like")
async def unlike_comment(place_id: ExistingPlaceId, comment_id: str, db: Db, user: CurrentUser) -> Comment:
    """Takes the current user's thumbs up back."""
    try:
        return await repo.set_like(db, place_id, comment_id, user.id, liked=False)
    except repo.CommentNotFound:
        raise _not_found()


@router.delete("/{comment_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_comment(place_id: ExistingPlaceId, comment_id: str, db: Db, user: CurrentUser) -> None:
    """Author or admin only."""
    try:
        await repo.delete_comment(db, place_id, comment_id, user)
    except repo.CommentNotFound:
        raise _not_found()
    except repo.NotAllowed:
        raise _forbidden()
