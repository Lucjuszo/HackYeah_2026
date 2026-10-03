from datetime import datetime
from typing import Annotated

from pydantic import BaseModel, StringConstraints

CommentText = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=2000)]


class CommentCreate(BaseModel):
    text: CommentText


class Comment(BaseModel):
    id: str
    place_id: str
    user_id: str
    text: str
    created_at: datetime
