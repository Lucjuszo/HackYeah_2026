"""Maps an OSM element (Overpass JSON with tags) to the facts our Place model can hold.

Only what OSM actually says is returned; unknown fields are left out so the caller can decide
whether to leave them unknown or fill them in.
"""

from dataclasses import dataclass, field
from typing import Any

from app.models.opening_hours import OpeningHours
from app.models.place import Address, Coordinates, OsmRef
from app.osm.opening_hours import UnsupportedOpeningHours, parse_opening_hours

YES = {"yes", "only", "designated", "limited", "required", "recommended"}
NO = {"no"}

CUISINES_PL = {
    "american": "amerykańska",
    "asian": "azjatycka",
    "bagel": "bajgle",
    "breakfast": "śniadania",
    "burger": "burgery",
    "cake": "ciasta",
    "chinese": "chińska",
    "coffee_shop": None,  # says nothing beyond "cafe"
    "french": "francuska",
    "georgian": "gruzińska",
    "greek": "grecka",
    "ice_cream": "lody",
    "indian": "indyjska",
    "international": "międzynarodowa",
    "italian": "włoska",
    "japanese": "japońska",
    "jewish": "żydowska",
    "kebab": "kebab",
    "korean": "koreańska",
    "mediterranean": "śródziemnomorska",
    "mexican": "meksykańska",
    "middle_eastern": "bliskowschodnia",
    "pierogi": "pierogi",
    "pizza": "pizza",
    "polish": "polska",
    "ramen": "ramen",
    "regional": "regionalna",
    "seafood": "owoce morza",
    "steak_house": "steki",
    "sushi": "sushi",
    "thai": "tajska",
    "turkish": "turecka",
    "ukrainian": "ukraińska",
    "vegan": "wegańska",
    "vegetarian": "wegetariańska",
    "vietnamese": "wietnamska",
}

# OSM tag -> feature shown on the place card when the tag is "yes"-like
FEATURE_TAGS = {
    "outdoor_seating": "Ogródek",
    "diet:vegan": "Opcje wegańskie",
    "diet:vegetarian": "Opcje wegetariańskie",
    "diet:gluten_free": "Opcje bezglutenowe",
    "takeaway": "Na wynos",
    "delivery": "Dowóz",
    "reservation": "Rezerwacje",
}


@dataclass
class OsmFacts:
    kind: str  # OSM amenity value: "cafe" | "restaurant"
    osm: OsmRef
    name: str
    address: Address
    coordinates: Coordinates
    amenities: dict[str, bool] = field(default_factory=dict)
    opening_hours: OpeningHours | None = None
    opening_hours_raw: str | None = None  # set when OSM has hours we couldn't parse
    features: list[str] = field(default_factory=list)
    cuisines: list[str] = field(default_factory=list)  # raw OSM cuisine values


def _flag(value: str | None) -> bool | None:
    if value is None:
        return None
    value = value.strip().lower()
    if value in YES:
        return True
    if value in NO:
        return False
    return None


def _coordinates(element: dict[str, Any]) -> Coordinates:
    point = element if "lat" in element else element.get("center")
    if not point:
        raise ValueError(f"{element['type']}/{element['id']} has no coordinates (query with 'out center')")
    return Coordinates(lat=point["lat"], lon=point["lon"])


def _toilet(tags: dict[str, str]) -> bool | None:
    toilets = _flag(tags.get("toilets"))
    if toilets is not None:
        return toilets
    # An accessible toilet implies a toilet; "toilets:wheelchair=no" says nothing about regular ones.
    return True if _flag(tags.get("toilets:wheelchair")) else None


def _amenities(kind: str, tags: dict[str, str]) -> dict[str, bool]:
    internet = (tags.get("internet_access") or "").lower()
    candidates = {
        "wifi": True if internet in ("wlan", "wifi", "yes") else _flag(internet or None),
        "computer_access": True if internet == "terminal" else None,
        "power_outlets": _flag(tags.get("power_supply")),
        "toilet": _toilet(tags),
        "wheelchair_accessible": _flag(tags.get("wheelchair")),
        "air_conditioning": _flag(tags.get("air_conditioning")),
        "food": True if kind == "restaurant" else _flag(tags.get("food")),
    }
    return {name: value for name, value in candidates.items() if value is not None}


def _features(tags: dict[str, str], cuisines: list[str]) -> list[str]:
    features = [label for tag, label in FEATURE_TAGS.items() if _flag(tags.get(tag))]
    names = [CUISINES_PL.get(c, c.replace("_", " ")) for c in cuisines]
    names = [n for n in names if n]
    if names:
        features.insert(0, f"Kuchnia: {', '.join(names)}"[:60])
    return features


def facts_from_element(element: dict[str, Any], *, default_city: str | None = None) -> OsmFacts:
    """default_city fills a missing addr:city, e.g. when the query was limited to one city's area."""
    tags = element.get("tags", {})
    kind = tags.get("amenity")
    if kind not in ("cafe", "restaurant"):
        raise ValueError(f"unsupported amenity {kind!r}")
    if not tags.get("name"):
        raise ValueError("element has no name")

    cuisines = [c.strip() for c in tags.get("cuisine", "").split(";") if c.strip()]
    facts = OsmFacts(
        kind=kind,
        osm=OsmRef(type=element["type"], id=element["id"]),
        name=tags["name"],
        address=Address(
            street=tags.get("addr:street"),
            house_number=tags.get("addr:housenumber"),
            postcode=tags.get("addr:postcode"),
            city=tags.get("addr:city") or default_city,
            country_code=tags.get("addr:country") or "pl",
        ),
        coordinates=_coordinates(element),
        amenities=_amenities(kind, tags),
        features=_features(tags, cuisines),
        cuisines=cuisines,
    )
    if raw := tags.get("opening_hours"):
        try:
            facts.opening_hours = parse_opening_hours(raw)
        except UnsupportedOpeningHours:
            facts.opening_hours_raw = raw
    return facts
