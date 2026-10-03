import pytest
from pydantic import ValidationError

from app.models.opening_hours import OpeningHours, OpeningPeriod, Weekday
from app.models.place import Address, Amenities, MenuItem, OsmRef, PlaceCreate


def test_example_place_is_valid(place_payload):
    place = PlaceCreate.model_validate(place_payload)
    assert place.amenities.wifi is True
    assert place.opening_hours.periods[0].day == Weekday.MONDAY


def test_minimal_place_defaults_to_unknown(minimal_payload):
    place = PlaceCreate.model_validate(minimal_payload)
    assert place.amenities == Amenities()
    assert all(v is None for v in place.amenities.model_dump().values())
    assert place.opening_hours is None
    assert place.usage_price is None
    assert place.atmosphere is None
    assert place.features == []
    assert place.menu == []
    assert place.osm is None


def test_name_is_stripped_and_required(minimal_payload):
    assert PlaceCreate.model_validate({**minimal_payload, "name": "  Kawa  "}).name == "Kawa"
    with pytest.raises(ValidationError):
        PlaceCreate.model_validate({**minimal_payload, "name": "   "})


@pytest.mark.parametrize("coords", [{"lat": 91, "lon": 0}, {"lat": 0, "lon": -181}, {"lat": 0}])
def test_invalid_coordinates(minimal_payload, coords):
    with pytest.raises(ValidationError):
        PlaceCreate.model_validate({**minimal_payload, "coordinates": coords})


class TestAddress:
    def test_country_code_normalized(self):
        assert Address(city="Kraków", country_code=" PL ").country_code == "pl"

    @pytest.mark.parametrize("code", ["pol", "p", "p1", ""])
    def test_country_code_rejected(self, code):
        with pytest.raises(ValidationError):
            Address(city="Kraków", country_code=code)

    def test_city_required(self):
        with pytest.raises(ValidationError):
            Address(country_code="pl")


class TestOpeningHours:
    def test_periods_sorted(self):
        hours = OpeningHours(
            periods=[
                OpeningPeriod(day=Weekday.TUESDAY, open="08:00", close="10:00"),
                OpeningPeriod(day=Weekday.MONDAY, open="14:00", close="16:00"),
                OpeningPeriod(day=Weekday.MONDAY, open="08:00", close="10:00"),
            ]
        )
        assert [(p.day, p.open) for p in hours.periods] == [(0, "08:00"), (0, "14:00"), (1, "08:00")]

    def test_close_at_midnight_allowed(self):
        assert OpeningPeriod(day=4, open="20:00", close="24:00").close == "24:00"

    @pytest.mark.parametrize(
        ("open_", "close"),
        [
            ("20:00", "02:00"),  # overnight must be split
            ("10:00", "10:00"),  # empty range
            ("24:00", "24:00"),  # 24:00 is only valid as close
            ("8:00", "10:00"),  # not zero-padded
            ("08:00", "25:00"),
            ("08:60", "10:00"),
        ],
    )
    def test_invalid_period(self, open_, close):
        with pytest.raises(ValidationError):
            OpeningPeriod(day=0, open=open_, close=close)

    @pytest.mark.parametrize("day", [-1, 7, "monday"])
    def test_invalid_day(self, day):
        with pytest.raises(ValidationError):
            OpeningPeriod(day=day, open="08:00", close="10:00")

    def test_always_open(self):
        assert OpeningHours(always_open=True).periods == []

    def test_always_open_with_periods_rejected(self):
        with pytest.raises(ValidationError):
            OpeningHours(always_open=True, periods=[{"day": 0, "open": "08:00", "close": "10:00"}])


class TestFeatures:
    def test_stripped_and_deduplicated_case_insensitive(self, minimal_payload):
        place = PlaceCreate.model_validate({**minimal_payload, "features": [" Cisza ", "cisza", "Wi-Fi", "WI-FI"]})
        assert place.features == ["Cisza", "Wi-Fi"]

    @pytest.mark.parametrize("features", [[""], ["   "], ["x" * 61], [f"f{i}" for i in range(21)]])
    def test_rejected(self, minimal_payload, features):
        with pytest.raises(ValidationError):
            PlaceCreate.model_validate({**minimal_payload, "features": features})


@pytest.mark.parametrize("value", ["quiet", "chatty", "lively"])
def test_atmosphere_values(minimal_payload, value):
    assert PlaceCreate.model_validate({**minimal_payload, "atmosphere": value}).atmosphere == value


def test_atmosphere_rejects_unknown(minimal_payload):
    with pytest.raises(ValidationError):
        PlaceCreate.model_validate({**minimal_payload, "atmosphere": "loud"})


def test_usage_price_is_free_text(minimal_payload):
    assert PlaceCreate.model_validate({**minimal_payload, "usage_price": "30-60"}).usage_price == "30-60"
    with pytest.raises(ValidationError):
        PlaceCreate.model_validate({**minimal_payload, "usage_price": " "})


class TestMenuItem:
    def test_currency_normalized(self):
        assert MenuItem(name="Kawa", price=900, currency="eur").currency == "EUR"

    def test_default_currency(self):
        assert MenuItem(name="Kawa", price=900).currency == "PLN"

    def test_negative_price_rejected(self):
        with pytest.raises(ValidationError):
            MenuItem(name="Kawa", price=-1)


class TestOsmRef:
    def test_url(self):
        assert OsmRef(type="way", id=123).url == "https://www.openstreetmap.org/way/123"

    @pytest.mark.parametrize("ref", [{"type": "area", "id": 1}, {"type": "node", "id": 0}])
    def test_invalid(self, ref):
        with pytest.raises(ValidationError):
            OsmRef.model_validate(ref)
