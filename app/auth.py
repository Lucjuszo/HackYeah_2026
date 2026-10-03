from typing import Annotated

from fastapi import Depends, Header

MOCK_USER_ID = "mock-user-1"


async def get_current_user_id(
    x_user_id: Annotated[
        str | None,
        Header(max_length=64, pattern=r"^[\w.-]+$", description="Mock auth: id of the acting user"),
    ] = None,
) -> str:
    """Placeholder until real auth: trusts the X-User-Id header, falls back to a fixed mock id.

    When auth lands, only this function changes (e.g. verify a token and return its subject);
    endpoints keep depending on CurrentUserId.
    """
    return x_user_id or MOCK_USER_ID


CurrentUserId = Annotated[str, Depends(get_current_user_id)]
