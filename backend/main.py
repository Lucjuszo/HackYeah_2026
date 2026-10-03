"""API dla frontu: wyszukiwanie miejsc w MongoDB po typie i filtrach.

pip install fastapi uvicorn pymongo tzdata
uvicorn main:app --reload
Test w przeglądarce: http://localhost:8000/docs

Oczekiwany dokument w kolekcji "places":
{
  "name": "Green Caffè Nero",
  "type": "cafe",
  "location": {"type": "Point", "coordinates": [21.0131, 52.2286]},  # [lon, lat]
  "wifi": true, "sockets": true, "computer": false, "toilet": true,
  "accessible": true, "air_conditioning": true, "food": true,
  "open_24h": false,
  "hours": {"mon": ["07:00", "23:00"], ..., "sun": null},  # null = zamknięte
  "price": "0-30",          # "0-30" | "30-60" | "60-90"
  "atmosphere": "calm",     # "calm" | "chat" | "loud"
  "custom_features": ["Pokoje wygłuszane"]
}
"""

import os
from datetime import datetime, timedelta
from typing import Literal
from zoneinfo import ZoneInfo

from bson import ObjectId
from bson.errors import InvalidId
from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field
from pymongo import MongoClient
from pymongo.errors import PyMongoError

# --- baza (nazwy ustal z kolegą od bazy) ---
MONGO_URL = os.environ.get("MONGO_URL", "mongodb://localhost:27017")
client = MongoClient(MONGO_URL, serverSelectionTimeoutMS=5000)
places = client["third_space"]["places"]

EARTH_RADIUS_M = 6_378_100
DAYS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
TIMEZONE = ZoneInfo("Europe/Warsaw")

app = FastAPI(title="third-space")
# front działa pod innym adresem niż backend, więc trzeba zezwolić na zapytania
app.add_middleware(
    CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"]
)


@app.exception_handler(PyMongoError)
def database_error(request, error):
    return JSONResponse(status_code=503, content={"detail": "Baza danych niedostępna"})


def build_query(place_type, lat, lon, radius, features, price, atmosphere) -> dict:
    """Składa filtr MongoDB z tego, co przysłał front (pomija puste pola)."""
    query = {}
    if place_type:
        query["type"] = place_type
    for name, value in features.items():
        if value is not None:
            query[name] = value
    if price:
        query["price"] = price
    if atmosphere:
        query["atmosphere"] = atmosphere
    if lat is not None and lon is not None:
        # okrąg o promieniu `radius` metrów; promień podaje się w radianach
        query["location"] = {
            "$geoWithin": {"$centerSphere": [[lon, lat], radius / EARTH_RADIUS_M]}
        }
    return query


def is_open_now(place: dict, now: datetime | None = None) -> bool:
    """Sprawdza po polu "hours", czy miejsce jest teraz otwarte."""
    if place.get("open_24h"):
        return True
    hours = place.get("hours") or {}
    now = now or datetime.now(TIMEZONE)
    current = now.strftime("%H:%M")

    today = hours.get(DAYS[now.weekday()])
    if today:
        opens, closes = today
        if opens <= closes and opens <= current < closes:
            return True
        if opens > closes and current >= opens:  # zamknięcie po północy
            return True

    # wczorajsze godziny, jeśli lokal zamyka się po północy (np. 18:00-02:00)
    yesterday = hours.get(DAYS[(now - timedelta(days=1)).weekday()])
    if yesterday:
        opens, closes = yesterday
        if opens > closes and current < closes:
            return True
    return False


@app.get("/places")
def get_places(
    place_type: str | None = None,
    lat: float | None = None,
    lon: float | None = None,
    radius: int = 10_000,
    # główne filtry
    wifi: bool | None = None,
    sockets: bool | None = None,
    open_24h: bool | None = None,
    open_now: bool = False,
    # dodatkowe filtry
    computer: bool | None = None,
    toilet: bool | None = None,
    accessible: bool | None = None,
    air_conditioning: bool | None = None,
    food: bool | None = None,
    price: Literal["0-30", "30-60", "60-90"] | None = None,
    atmosphere: Literal["calm", "chat", "loud"] | None = None,
    limit: int = Query(50, ge=1, le=200),
) -> list[dict]:
    """Zwraca miejsca pasujące do typu i/lub filtrów. Każdy parametr jest opcjonalny."""
    features = {
        "wifi": wifi,
        "sockets": sockets,
        "open_24h": open_24h,
        "computer": computer,
        "toilet": toilet,
        "accessible": accessible,
        "air_conditioning": air_conditioning,
        "food": food,
    }
    query = build_query(place_type, lat, lon, radius, features, price, atmosphere)

    results = []
    for place in places.find(query):
        # "otwarte teraz" zależy od aktualnej godziny, więc liczymy je w Pythonie
        if open_now and not is_open_now(place):
            continue
        place["_id"] = str(place["_id"])  # ObjectId nie zamienia się sam na JSON
        results.append(place)
        if len(results) >= limit:
            break
    return results


class NewFeature(BaseModel):
    feature: str = Field(min_length=1, max_length=60)


@app.post("/places/{place_id}/features")
def add_feature(place_id: str, body: NewFeature) -> dict:
    """Dodaje cechę wpisaną przez użytkownika (np. "Pokoje wygłuszane")."""
    try:
        object_id = ObjectId(place_id)
    except InvalidId:
        raise HTTPException(status_code=400, detail="Niepoprawne id miejsca")

    # $addToSet nie doda drugi raz tej samej cechy
    result = places.update_one(
        {"_id": object_id}, {"$addToSet": {"custom_features": body.feature.strip()}}
    )
    if result.matched_count == 0:
        raise HTTPException(status_code=404, detail="Nie ma takiego miejsca")
    return {"ok": True}