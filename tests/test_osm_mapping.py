import pytest
from pydantic import ValidationError

from app.osm.mapping import facts_from_element


def element(tags: dict, **extra) -> dict:
    base = {"type": "node", "id": 123, "lat": 50.06, "lon": 19.94}
    return {**base, **extra, "tags": {"amenity": "cafe", "name": "Kawiarnia", "addr:street": "Długa",
                                      "addr:housenumber": "1", **tags}}


def test_basic_fields():
    facts = facts_from_element(element({"addr:postcode": "31-001", "addr:city": "Kraków"}))
    assert facts.kind == "cafe"
    assert facts.name == "Kawiarnia"
    assert (facts.osm.type, facts.osm.id) == ("node", 123)
    assert (facts.coordinates.lat, facts.coordinates.lon) == (50.06, 19.94)
    assert facts.address.model_dump() == {
        "street": "Długa", "house_number": "1", "postcode": "31-001", "city": "Kraków", "country_code": "pl"
    }
    assert facts.amenities == {}
    assert facts.features == []
    assert facts.opening_hours is None


def test_way_uses_center():
    raw = element({}, type="way", center={"lat": 50.1, "lon": 19.9})
    del raw["lat"], raw["lon"]
    facts = facts_from_element(raw, default_city="Kraków")
    assert (facts.osm.type, facts.coordinates.lat) == ("way", 50.1)


def test_default_city_only_when_missing():
    assert facts_from_element(element({}), default_city="Kraków").address.city == "Kraków"
    assert facts_from_element(element({"addr:city": "Wieliczka"}), default_city="Kraków").address.city == "Wieliczka"
    with pytest.raises(ValidationError):
        facts_from_element(element({}))  # no city at all


@pytest.mark.parametrize(
    ("tags", "expected"),
    [
        ({"internet_access": "wlan"}, {"wifi": True}),
        ({"internet_access": "no"}, {"wifi": False}),
        ({"internet_access": "customers"}, {"wifi": True}),
        ({"internet_access": "terminal"}, {"computer_access": True}),
        ({"wheelchair": "limited"}, {"wheelchair_accessible": True}),
        ({"wheelchair": "no"}, {"wheelchair_accessible": False}),
        ({"toilets": "no"}, {"toilet": False}),
        ({"toilets:wheelchair": "yes"}, {"toilet": True}),
        ({"toilets:wheelchair": "no"}, {}),
        ({"air_conditioning": "yes"}, {"air_conditioning": True}),
        ({"power_supply": "yes"}, {"power_outlets": True}),
        ({"wheelchair": "maybe?"}, {}),
    ],
)
def test_amenities(tags, expected):
    assert facts_from_element(element(tags), default_city="Kraków").amenities == expected


def test_restaurant_serves_food():
    facts = facts_from_element(element({"amenity": "restaurant"}), default_city="Kraków")
    assert facts.amenities == {"food": True}


def test_features_from_tags_and_cuisine():
    tags = {"cuisine": "italian;pizza;coffee_shop;something_new", "outdoor_seating": "yes", "diet:vegan": "only",
            "takeaway": "no"}
    facts = facts_from_element(element(tags), default_city="Kraków")
    assert facts.features == ["Kuchnia: włoska, pizza, something new", "Ogródek", "Opcje wegańskie"]
    assert facts.cuisines == ["italian", "pizza", "coffee_shop", "something_new"]


def test_opening_hours():
    facts = facts_from_element(element({"opening_hours": "Mo-Su 10:00-18:00"}), default_city="Kraków")
    assert len(facts.opening_hours.periods) == 7
    assert facts.opening_hours_raw is None


def test_unparseable_opening_hours_kept_raw():
    facts = facts_from_element(element({"opening_hours": "Mo-Su 10:00+"}), default_city="Kraków")
    assert facts.opening_hours is None
    assert facts.opening_hours_raw == "Mo-Su 10:00+"


@pytest.mark.parametrize("tags", [{"amenity": "bar"}, {"name": ""}])
def test_rejected(tags):
    with pytest.raises(ValueError):
        facts_from_element(element(tags), default_city="Kraków")
