from typing import Annotated

from fastapi import APIRouter, HTTPException, Query, status

from app.auth import CurrentUserId
from app.models.comment import Comment, CommentCreate
from app.repositories import comments as repo
from app.routers.deps import Db, ExistingPlaceId

router = APIRouter(prefix="/places/{place_id}/comments", tags=["comments"])


@router.post("", status_code=status.HTTP_201_CREATED)
async def create_comment(place_id: ExistingPlaceId, body: CommentCreate, db: Db, user_id: CurrentUserId) -> Comment:
    return await repo.create_comment(db, place_id, user_id, body.text)


@router.get("")
async def list_comments(
    place_id: ExistingPlaceId,
    db: Db,
    limit: Annotated[int, Query(ge=1, le=100)] = 20,
    skip: Annotated[int, Query(ge=0)] = 0,
) -> list[Comment]:
    return await repo.list_comments(db, place_id, limit=limit, skip=skip)


@router.delete("/{comment_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_comment(place_id: ExistingPlaceId, comment_id: str, db: Db, user_id: CurrentUserId) -> None:
    try:
        await repo.delete_comment(db, place_id, comment_id, user_id)
    except repo.CommentNotFound:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Comment not found")
    except repo.NotCommentAuthor:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Only the author can delete this comment")
