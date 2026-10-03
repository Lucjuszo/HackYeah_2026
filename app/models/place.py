from datetime import datetime
from enum import StrEnum
from typing import Annotated, Self

from annotated_types import MaxLen
from pydantic import AfterValidator, BaseModel, Field, StringConstraints, model_validator

from app.models.opening_hours import OpeningHours
from app.models.types import CountryCode, CurrencyCode, NonEmptyStr


class OsmType(StrEnum):
    NODE = "node"
    WAY = "way"
    RELATION = "relation"


class OsmRef(BaseModel):
    """Link to an OSM element. OSM ids are unique only within a type, so both fields are needed."""

    type: OsmType
    id: int = Field(gt=0)

    @property
    def url(self) -> str:
        return f"https://www.openstreetmap.org/{self.type}/{self.id}"


class Coordinates(BaseModel):
    lat: float = Field(ge=-90, le=90)
    lon: float = Field(ge=-180, le=180)


class Address(BaseModel):
    # Field names mirror OSM addr:* tags, so mapping from Nominatim/Overpass is 1:1.
    street: NonEmptyStr | None = None
    house_number: NonEmptyStr | None = None
    postcode: NonEmptyStr | None = None
    city: NonEmptyStr
    country_code: CountryCode = Field(description="ISO 3166-1 alpha-2, e.g. 'pl'")


class Amenities(BaseModel):
    """Yes/no search filters. None = unknown, False = confirmed absent."""

    # Main filters
    wifi: bool | None = None
    power_outlets: bool | None = None
    # Additional filters
    computer_access: bool | None = None
    toilet: bool | None = None
    wheelchair_accessible: bool | None = None
    air_conditioning: bool | None = None
    food: bool | None = None


class Atmosphere(StrEnum):
    QUIET = "quiet"  # spokojnie
    CHATTY = "chatty"  # na pogaduchy
    LIVELY = "lively"  # gwarno


def _dedupe_case_insensitive(items: list[str]) -> list[str]:
    seen: set[str] = set()
    result = []
    for item in items:
        if item.casefold() not in seen:
            seen.add(item.casefold())
            result.append(item)
    return result


Feature = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=60)]
Features = Annotated[list[Feature], AfterValidator(_dedupe_case_insensitive), MaxLen(20)]


class MenuItem(BaseModel):
    name: NonEmptyStr
    category: NonEmptyStr | None = None
    description: str | None = None
    # Integer minor units (grosze) – avoids float rounding and Decimal128 conversion in Mongo.
    price: int = Field(ge=0, description="Price in minor units, e.g. 1500 = 15.00 PLN")
    currency: CurrencyCode = "PLN"


class PlaceCreate(BaseModel):
    name: NonEmptyStr
    address: Address
    coordinates: Coordinates
    amenities: Amenities = Amenities()
    opening_hours: OpeningHours | None = Field(None, description="None = unknown")
    # Fee for using the place (not menu prices). Free-form until the price model is settled.
    usage_price: NonEmptyStr | None = Field(None, examples=["0-30", "30-60", "60-90"])
    atmosphere: Atmosphere | None = None
    features: Features = Field([], description="User-defined extras shown on the place card, e.g. 'Pokoje wygłuszane'")
    menu: list[MenuItem] = []
    osm: OsmRef | None = None


class PlaceUpdate(BaseModel):
    """Partial update (PATCH).

    - omitted field  -> unchanged
    - explicit null  -> cleared (only for nullable fields: opening_hours, usage_price, atmosphere, osm)
    - amenities      -> merged flag by flag, so {"amenities": {"wifi": true}} leaves other flags alone
    - other objects and lists (address, opening_hours, features, menu) are replaced as a whole
    """

    name: NonEmptyStr | None = None
    address: Address | None = None
    coordinates: Coordinates | None = None
    amenities: Amenities | None = None
    opening_hours: OpeningHours | None = None
    usage_price: NonEmptyStr | None = None
    atmosphere: Atmosphere | None = None
    features: Features | None = None
    menu: list[MenuItem] | None = None
    osm: OsmRef | None = None

    @model_validator(mode="after")
    def _check(self) -> Self:
        if not self.model_fields_set:
            raise ValueError("No fields to update")
        non_nullable = ("name", "address", "coordinates", "amenities", "features", "menu")
        nulls = [f for f in non_nullable if f in self.model_fields_set and getattr(self, f) is None]
        if nulls:
            raise ValueError(f"Fields cannot be null: {', '.join(nulls)}")
        return self


class RatingSummary(BaseModel):
    average: float | None = Field(None, description="None until the first rating")
    count: int = 0


class PhotoVariant(BaseModel):
    url: str
    width: int
    height: int
    size: int


class Photo(BaseModel):
    """`url`/`width`/`height`/`size` describe the full version (longer side <= MAX_PHOTO_DIMENSION)."""

    id: str
    url: str
    content_type: str
    width: int
    height: int
    size: int
    thumbnail: PhotoVariant | None = Field(
        None, description="Small version for lists and maps (longer side <= THUMBNAIL_DIMENSION)"
    )
    uploaded_by: str | None = None
    uploaded_by_name: str | None = Field(None, description="Uploader's display name at the time of upload")
    created_at: datetime


class PlaceSort(StrEnum):
    DISTANCE = "distance"  # closest first; needs lat/lon
    RATING = "rating"  # best average first, unrated last
    NAME = "name"
    NEWEST = "newest"
    OLDEST = "oldest"


class Place(PlaceCreate):
    id: str
    photos: list[Photo] = []
    rating: RatingSummary = RatingSummary()
    is_mock: bool = Field(False, description="Demo/test data loaded by a script")
    mock_fields: list[str] = Field(
        [],
        description="Fields holding made-up demo values (e.g. 'menu', 'amenities.wifi'); the rest is real data",
    )
    created_by: str | None = None
    updated_by: str | None = None
    created_at: datetime
    updated_at: datetime
    distance_m: float | None = Field(None, description="Distance from the searched point; only in searches by lat/lon")


class PlaceSummary(BaseModel):
    """Light version of Place for maps and lists: no menu, opening hours or photo list."""

    id: str
    name: str
    address: Address
    coordinates: Coordinates
    amenities: Amenities
    usage_price: str | None = None
    atmosphere: Atmosphere | None = None
    rating: RatingSummary
    thumbnail_url: str | None = Field(None, description="Thumbnail of the first photo")
    photo_count: int = 0
    open_now: bool | None = Field(None, description="None = opening hours unknown")
    is_mock: bool = False
    distance_m: float | None = None
