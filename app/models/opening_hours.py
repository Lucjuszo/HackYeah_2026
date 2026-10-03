from dataclasses import dataclass
from datetime import datetime, time, timedelta
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


@dataclass
class OpenStatus:
    open_now: bool
    closes_at: datetime | None = None  # when open: end of the current opening (None = always open)
    opens_at: datetime | None = None  # when closed: start of the next opening within a week (None = never)


def _at(day: datetime, hhmm: str) -> datetime:
    """`hhmm` on the date of `day`, in its time zone; "24:00" is the next midnight."""
    if hhmm == "24:00":
        return datetime.combine(day.date() + timedelta(days=1), time(0), day.tzinfo)
    hours, minutes = map(int, hhmm.split(":"))
    return datetime.combine(day.date(), time(hours, minutes), day.tzinfo)


class OpeningHours(BaseModel):
    always_open: bool = False
    periods: list[OpeningPeriod] = []

    @model_validator(mode="after")
    def _check(self) -> Self:
        if self.always_open and self.periods:
            raise ValueError("always_open places must not define periods")
        self.periods.sort(key=lambda p: (p.day, p.open))
        return self


    def status_at(self, local: datetime) -> OpenStatus:
        """Open now? Until when / from when. Overnight hours stored as two periods count as one opening."""
        if self.always_open:
            return OpenStatus(open_now=True)
        # Concrete openings from yesterday (may run past midnight) to a week ahead, merged where they touch.
        openings: list[list[datetime]] = []
        for offset in range(-1, 8):
            day = local + timedelta(days=offset)
            for period in self.periods:
                if period.day != day.weekday():
                    continue
                start, end = _at(day, period.open), _at(day, period.close)
                if openings and start <= openings[-1][1]:
                    openings[-1][1] = max(openings[-1][1], end)
                else:
                    openings.append([start, end])
        horizon = _at(local + timedelta(days=7), "24:00")
        for start, end in openings:
            if start <= local < end:
                # Open around the clock for the whole week we look at: no closing time to show.
                return OpenStatus(open_now=True, closes_at=end if end < horizon else None)
            if start > local:
                return OpenStatus(open_now=False, opens_at=start)
        return OpenStatus(open_now=False)
