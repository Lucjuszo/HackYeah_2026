from datetime import datetime
from zoneinfo import ZoneInfo

import pytest

from app.models.opening_hours import OpeningHours

WARSAW = ZoneInfo("Europe/Warsaw")


def at(day: int, hhmm: str) -> datetime:
    """Week of Monday 2026-10-05; day 0 = Monday."""
    hours, minutes = map(int, hhmm.split(":"))
    return datetime(2026, 10, 5 + day, hours, minutes, tzinfo=WARSAW)


def hours(*periods: tuple[int, str, str]) -> OpeningHours:
    return OpeningHours(periods=[{"day": d, "open": o, "close": c} for d, o, c in periods])


WEEKDAYS_8_TO_18 = hours(*[(d, "08:00", "18:00") for d in range(5)])


def test_open_until_closing_time():
    status = WEEKDAYS_8_TO_18.status_at(at(2, "14:30"))
    assert status.open_now is True
    assert status.closes_at == at(2, "18:00")
    assert status.opens_at is None


def test_closed_before_opening_today():
    status = WEEKDAYS_8_TO_18.status_at(at(2, "06:00"))
    assert status.open_now is False
    assert status.opens_at == at(2, "08:00")
    assert status.closes_at is None


def test_closed_in_the_evening_opens_next_morning():
    assert WEEKDAYS_8_TO_18.status_at(at(2, "20:00")).opens_at == at(3, "08:00")


def test_weekend_opens_on_monday():
    assert WEEKDAYS_8_TO_18.status_at(at(5, "12:00")).opens_at == at(7, "08:00")


@pytest.mark.parametrize(("moment", "open_now"), [("08:00", True), ("17:59", True), ("18:00", False), ("07:59", False)])
def test_boundaries(moment, open_now):
    assert WEEKDAYS_8_TO_18.status_at(at(1, moment)).open_now is open_now


def test_overnight_split_counts_as_one_opening():
    # Fri 20:00 - Sat 02:00, stored split at midnight.
    bar = hours((4, "20:00", "24:00"), (5, "00:00", "02:00"))
    assert bar.status_at(at(4, "23:00")).closes_at == at(5, "02:00")
    after_midnight = bar.status_at(at(5, "01:00"))
    assert after_midnight.open_now is True
    assert after_midnight.closes_at == at(5, "02:00")


def test_sunday_night_into_monday():
    bar = hours((6, "20:00", "24:00"), (0, "00:00", "03:00"))
    assert bar.status_at(at(6, "22:00")).closes_at == at(7, "03:00")
    assert bar.status_at(at(0, "01:00")).closes_at == at(0, "03:00")  # Monday early: from the previous Sunday


def test_lunch_break():
    shop = hours((0, "09:00", "13:00"), (0, "14:00", "18:00"))
    assert shop.status_at(at(0, "12:00")).closes_at == at(0, "13:00")
    assert shop.status_at(at(0, "13:30")).opens_at == at(0, "14:00")


def test_always_open():
    status = OpeningHours(always_open=True).status_at(at(3, "03:00"))
    assert (status.open_now, status.closes_at, status.opens_at) == (True, None, None)


def test_every_day_round_the_clock_has_no_closing_time():
    nonstop = hours(*[(d, "00:00", "24:00") for d in range(7)])
    status = nonstop.status_at(at(3, "03:00"))
    assert status.open_now is True
    assert status.closes_at is None


def test_no_periods_means_never_open():
    status = OpeningHours().status_at(at(0, "12:00"))
    assert (status.open_now, status.closes_at, status.opens_at) == (False, None, None)


def test_times_keep_the_zone_offset():
    status = WEEKDAYS_8_TO_18.status_at(at(2, "14:30"))
    assert status.closes_at.isoformat() == "2026-10-07T18:00:00+02:00"
