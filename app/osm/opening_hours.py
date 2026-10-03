"""Parser for the common subset of OSM's opening_hours syntax.

Supported: "24/7", rules separated by ";" or ", ", day selectors ("Mo-Fr", "Sa,Su", "Fr-Mo"),
several time ranges ("08:00-12:00,13:00-17:00"), overnight ranges ("18:00-02:00"),
"off"/"closed", rules without days (= every day) and later rules overriding earlier ones.
Public/school holiday rules (PH, SH) are skipped – the model has no holidays.

Anything else (months, week numbers, open ends "20:00+", comments, sunrise...) raises
UnsupportedOpeningHours rather than guessing. Spec: https://wiki.openstreetmap.org/wiki/Key:opening_hours
"""

import re

from app.models.opening_hours import OpeningHours, OpeningPeriod

DAYS = ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
DAY_MINUTES = 24 * 60

_DAY_SELECTOR = r"(?:Mo|Tu|We|Th|Fr|Sa|Su|PH)(?:-(?:Mo|Tu|We|Th|Fr|Sa|Su))?"
_TIME_RANGE = r"\d{1,2}:\d{2}\s*-\s*\d{1,2}:\d{2}"
# ", " after a time starts another rule ("Mo-Fr 08:00-20:00, Sa 10:00-14:00"); a comma between
# days ("Sa,Su") is part of the day selector and isn't preceded by a digit.
_RULE_SEPARATOR = re.compile(rf";|(?<=\d|f|d),\s*(?={_DAY_SELECTOR}\b)")
_RULE = re.compile(
    rf"^(?:(?P<days>{_DAY_SELECTOR}(?:\s*,\s*{_DAY_SELECTOR})*)\s+)?"
    rf"(?P<times>off|closed|{_TIME_RANGE}(?:\s*,\s*{_TIME_RANGE})*)$"
)


class UnsupportedOpeningHours(ValueError):
    pass


def _minutes(hhmm: str) -> int:
    hours, minutes = map(int, hhmm.strip().split(":"))
    if hours > 24 or minutes > 59 or (hours == 24 and minutes):
        raise UnsupportedOpeningHours(f"invalid time {hhmm!r}")
    return hours * 60 + minutes


def _hhmm(minutes: int) -> str:
    return f"{minutes // 60:02d}:{minutes % 60:02d}"


def _days(selector: str | None) -> list[int]:
    if selector is None:
        return list(range(7))
    days: list[int] = []
    for part in selector.replace(" ", "").split(","):
        if part == "PH":
            continue  # "Mo-Fr,PH 10:00-18:00": keep the weekdays, ignore the holiday part
        start, _, end = part.partition("-")
        first = DAYS.index(start)
        last = DAYS.index(end) if end else first
        span = (last - first) % 7  # wraps around, e.g. Fr-Mo
        days.extend((first + i) % 7 for i in range(span + 1))
    return days


def _ranges(times: str) -> list[tuple[int, int]]:
    if times in ("off", "closed"):
        return []
    ranges = []
    for time_range in times.split(","):
        open_, close = (_minutes(t) for t in time_range.split("-"))
        if open_ >= DAY_MINUTES:
            raise UnsupportedOpeningHours(f"invalid opening time in {time_range!r}")
        if close <= open_:
            close += DAY_MINUTES  # past midnight
        ranges.append((open_, close))
    return ranges


def parse_opening_hours(value: str) -> OpeningHours:
    value = value.strip()
    if value == "24/7":
        return OpeningHours(always_open=True)

    week: dict[int, list[tuple[int, int]]] = {day: [] for day in range(7)}
    for rule in filter(None, (r.strip() for r in _RULE_SEPARATOR.split(value))):
        if rule.startswith(("PH", "SH")) and not rule.startswith("PH,"):
            continue
        match = _RULE.match(rule)
        if not match:
            raise UnsupportedOpeningHours(f"unsupported rule {rule!r}")
        days = _days(match["days"])
        if not days:
            continue  # selector was only "PH"
        ranges = _ranges(match["times"])
        for day in days:
            week[day] = ranges  # later rules override earlier ones for the same day

    if all(ranges == [(0, DAY_MINUTES)] for ranges in week.values()):
        return OpeningHours(always_open=True)

    periods = []
    for day, ranges in week.items():
        for open_, close in ranges:
            # Split overnight ranges at midnight, as the model requires.
            periods.append(OpeningPeriod(day=day, open=_hhmm(open_), close=_hhmm(min(close, DAY_MINUTES))))
            if close > DAY_MINUTES:
                periods.append(OpeningPeriod(day=(day + 1) % 7, open="00:00", close=_hhmm(close - DAY_MINUTES)))
    if not periods:
        raise UnsupportedOpeningHours("no opening times")
    return OpeningHours(periods=periods)
