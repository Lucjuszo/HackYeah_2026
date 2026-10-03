import pytest

from app.osm.opening_hours import UnsupportedOpeningHours, parse_opening_hours


def periods(value: str) -> list[tuple[int, str, str]]:
    return [(p.day, p.open, p.close) for p in parse_opening_hours(value).periods]


def every_day(open_: str, close: str) -> list[tuple[int, str, str]]:
    return [(day, open_, close) for day in range(7)]


@pytest.mark.parametrize("value", ["24/7", "Mo-Su 00:00-24:00", " 24/7 "])
def test_always_open(value):
    hours = parse_opening_hours(value)
    assert hours.always_open is True
    assert hours.periods == []


def test_every_day():
    assert periods("Mo-Su 12:00-22:00") == every_day("12:00", "22:00")


def test_no_day_selector_means_every_day():
    assert periods("12:00-22:00") == every_day("12:00", "22:00")


def test_several_rules():
    assert periods("Mo-Fr 08:00-20:00; Sa 10:00-14:00") == [
        *[(day, "08:00", "20:00") for day in range(5)],
        (5, "10:00", "14:00"),
    ]


def test_comma_as_rule_separator():
    assert periods("Mo-Sa 08:00-22:00, Su 10:00-22:00") == [
        *[(day, "08:00", "22:00") for day in range(6)],
        (6, "10:00", "22:00"),
    ]


def test_day_list_is_not_a_rule_separator():
    assert periods("Sa,Su 10:00-14:00") == [(5, "10:00", "14:00"), (6, "10:00", "14:00")]


def test_several_ranges_per_day():
    assert periods("Mo 08:00-12:00,13:00-17:00") == [(0, "08:00", "12:00"), (0, "13:00", "17:00")]


def test_overnight_split_at_midnight():
    assert periods("Fr 20:00-02:00") == [(4, "20:00", "24:00"), (5, "00:00", "02:00")]


def test_overnight_on_sunday_wraps_to_monday():
    assert periods("Su 22:00-01:00") == [(0, "00:00", "01:00"), (6, "22:00", "24:00")]


def test_closing_at_midnight():
    assert periods("Mo 12:00-24:00") == [(0, "12:00", "24:00")]
    assert periods("Mo 12:00-00:00") == [(0, "12:00", "24:00")]


def test_later_rule_overrides_earlier():
    assert periods("Mo-Su 10:00-22:00; Su 12:00-18:00") == [
        *[(day, "10:00", "22:00") for day in range(6)],
        (6, "12:00", "18:00"),
    ]


def test_off_removes_days():
    assert periods("Mo-Su 10:00-20:00; Mo off") == [(day, "10:00", "20:00") for day in range(1, 7)]


def test_wrapping_day_range():
    assert [p[0] for p in periods("Fr-Mo 10:00-12:00")] == [0, 4, 5, 6]


def test_holiday_rules_ignored():
    assert periods("Mo-Fr 09:00-17:00; PH off") == [(day, "09:00", "17:00") for day in range(5)]
    assert periods("Mo-Fr,PH 09:00-17:00") == [(day, "09:00", "17:00") for day in range(5)]


@pytest.mark.parametrize(
    "value",
    [
        "Mo-Su 12:00-20:00+",  # open end
        "Mo-Su 08:00+",
        "Jun 8-9 off",  # months
        "Mo-Fr 08:00-18:00; Sa-Sun 09:00-18:00",  # typo
        "closed",  # closed every day: nothing to model
        "Mo 25:00-26:00",
        "sunrise-sunset",
        "",
    ],
)
def test_unsupported(value):
    with pytest.raises(UnsupportedOpeningHours):
        parse_opening_hours(value)
