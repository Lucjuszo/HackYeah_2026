from enum import IntEnum
from typing import Annotated, Self

from pydantic import BaseModel, StringConstraints, model_validator

# "HH:MM", zero-padded, so times compare correctly as plain strings (also in Mongo queries).
OpenTime = Annotated[str, StringConstraints(pattern=r"^(?:[01]\d|2[0-3]):[0-5]\d$")]
CloseTime = Annotated[str, StringConstraints(pattern=r"^(?:(?:[01]\d|2[0-3]):[0-5]\d|24:00)$")]


class Weekday(IntEnum):
    """Same numbering as datetime.weekday(): Monday = 0."""

    MONDAY = 0
    TUESDAY = 1
    WEDNESDAY = 2
    THURSDAY = 3
    FRIDAY = 4
    SATURDAY = 5
    SUNDAY = 6


class OpeningPeriod(BaseModel):
    """One continuous opening within a single day, in the place's local time.

    Overnight hours are split at midnight, e.g. Fri 20:00-02:00 becomes
    Fri 20:00-24:00 + Sat 00:00-02:00. This keeps "open now" a single query:
    {"periods": {"$elemMatch": {"day": today, "open": {"$lte": hhmm}, "close": {"$gt": hhmm}}}}
    """

    day: Weekday
    open: OpenTime
    close: CloseTime

    @model_validator(mode="after")
    def _close_after_open(self) -> Self:
        if self.close <= self.open:
            raise ValueError("close must be after open; split overnight hours at 24:00")
        return self


class OpeningHours(BaseModel):
    always_open: bool = False
    periods: list[OpeningPeriod] = []

    @model_validator(mode="after")
    def _check(self) -> Self:
        if self.always_open and self.periods:
            raise ValueError("always_open places must not define periods")
        self.periods.sort(key=lambda p: (p.day, p.open))
        return self
