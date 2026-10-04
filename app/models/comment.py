from datetime import datetime
from typing import Annotated

from pydantic import BaseModel, Field, StringConstraints

CommentText = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=2000)]


class CommentCreate(BaseModel):
    text: CommentText


class CommentUpdate(BaseModel):
    text: CommentText


class Comment(BaseModel):
    id: str
    place_id: str
    user_id: str
    user_name: str | None = Field(None, description="Author's display name at the time of writing")
    text: str
    is_mock: bool = Field(False, description="Demo/test data loaded by a script")
    created_at: datetime
    edited_at: datetime | None = None
    edited_by: str | None = Field(None, description="Set when edited; differs from user_id when an admin edited it")
    likes: int = Field(0, description="Number of thumbs up; lists show the most liked first")
    liked_by: list[str] = Field(default_factory=list, description="Ids of the users who gave a thumbs up")
