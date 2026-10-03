"""Per-user limits for write-heavy endpoints (photo uploads, comments).

In memory and per process: enough for one API instance; behind several workers each counts on its own.
"""

import time
from collections import defaultdict, deque
from collections.abc import Callable

from fastapi import HTTPException, status

WINDOW_S = 3600


class RateLimiter:
    def __init__(self, name: str, per_hour: Callable[[], int]) -> None:
        self.name = name
        self._per_hour = per_hour  # read on every call, so settings changes (and tests) apply immediately
        self._hits: dict[str, deque[float]] = defaultdict(deque)

    def check(self, user_id: str) -> None:
        """Counts one action of the user or raises 429 with Retry-After."""
        limit = self._per_hour()
        if limit <= 0:
            return
        now = time.monotonic()
        hits = self._hits[user_id]
        while hits and hits[0] <= now - WINDOW_S:
            hits.popleft()
        if len(hits) >= limit:
            retry_after = int(hits[0] + WINDOW_S - now) + 1
            raise HTTPException(
                status.HTTP_429_TOO_MANY_REQUESTS,
                f"Too many {self.name}: max {limit} per hour",
                headers={"Retry-After": str(retry_after)},
            )
        hits.append(now)

    def reset(self) -> None:
        self._hits.clear()
