"""Plausible made-up values for fields OpenStreetMap doesn't know about (demo data only)."""

import random

from app.models.opening_hours import OpeningHours, OpeningPeriod
from app.models.place import Atmosphere, MenuItem

# Probability that a flag is true, per kind of place.
AMENITY_ODDS = {
    "cafe": {
        "wifi": 0.85,
        "power_outlets": 0.6,
        "computer_access": 0.05,
        "toilet": 0.9,
        "wheelchair_accessible": 0.4,
        "air_conditioning": 0.45,
        "food": 0.75,
    },
    "restaurant": {
        "wifi": 0.7,
        "power_outlets": 0.3,
        "computer_access": 0.02,
        "toilet": 0.98,
        "wheelchair_accessible": 0.5,
        "air_conditioning": 0.55,
        "food": 1.0,
    },
}

# Weekly schedules: (first day, last day, open, close); Monday = 0.
HOURS = {
    "cafe": [
        [(0, 4, "08:00", "20:00"), (5, 6, "09:00", "20:00")],
        [(0, 6, "07:30", "19:00")],
        [(0, 4, "09:00", "21:00"), (5, 6, "10:00", "21:00")],
        [(0, 6, "10:00", "22:00")],
    ],
    "restaurant": [
        [(0, 6, "12:00", "22:00")],
        [(0, 3, "12:00", "22:00"), (4, 5, "12:00", "24:00"), (6, 6, "12:00", "21:00")],
        [(0, 4, "11:00", "22:00"), (5, 6, "12:00", "23:00")],
        [(1, 6, "13:00", "22:00")],
    ],
}

FEATURES = {
    "cafe": ["Ciche kąciki do pracy", "Duże stoły", "Gry planszowe", "Książki na półkach", "Przyjazne psom",
             "Kawa speciality", "Alternatywne metody parzenia", "Mleko roślinne bez dopłaty"],
    "restaurant": ["Ogródek", "Menu lunchowe", "Sala dla grup", "Kącik dla dzieci", "Rezerwacje online",
                   "Muzyka na żywo w weekendy", "Lokalne produkty"],
}

# (category, name, min price PLN, max price PLN)
MENUS = {
    "cafe": [("Kawa", "Espresso", 8, 11), ("Kawa", "Cappuccino", 12, 16), ("Kawa", "Flat white", 14, 18),
             ("Kawa", "Latte", 13, 17), ("Kawa", "Cold brew", 14, 19), ("Herbata", "Herbata liściasta", 10, 14),
             ("Herbata", "Matcha latte", 16, 21), ("Jedzenie", "Croissant", 9, 13),
             ("Jedzenie", "Kanapka z hummusem", 18, 26), ("Desery", "Sernik", 15, 20),
             ("Desery", "Szarlotka na ciepło", 14, 19), ("Desery", "Brownie", 12, 16)],
    "italian": [("Pizza", "Margherita", 32, 42), ("Pizza", "Diavola", 38, 48), ("Makarony", "Spaghetti carbonara", 36, 46),
                ("Makarony", "Tagliatelle z grzybami", 38, 49), ("Przystawki", "Bruschetta", 18, 26),
                ("Desery", "Tiramisu", 20, 28), ("Napoje", "Lemoniada", 14, 18)],
    "asian": [("Dania", "Ramen tonkotsu", 39, 49), ("Dania", "Pad thai z kurczakiem", 36, 45),
              ("Dania", "Pho bo", 34, 42), ("Sushi", "Zestaw maki (16 szt.)", 45, 62), ("Przystawki", "Gyoza (6 szt.)", 22, 29),
              ("Napoje", "Herbata jaśminowa", 10, 14)],
    "burger": [("Burgery", "Classic burger", 34, 42), ("Burgery", "Cheeseburger", 36, 45), ("Burgery", "Burger wege", 34, 42),
               ("Dodatki", "Frytki belgijskie", 12, 16), ("Dodatki", "Krążki cebulowe", 14, 18), ("Napoje", "Shake waniliowy", 16, 21)],
    "polish": [("Zupy", "Żurek", 18, 26), ("Zupy", "Rosół z makaronem", 16, 22), ("Dania główne", "Pierogi ruskie", 28, 36),
               ("Dania główne", "Kotlet schabowy z ziemniakami", 39, 49), ("Dania główne", "Placki ziemniaczane", 29, 38),
               ("Dania główne", "Gołąbki w sosie pomidorowym", 34, 42), ("Desery", "Sernik krakowski", 16, 22),
               ("Napoje", "Kompot", 8, 12)],
}
CUISINE_MENU = {
    "italian": "italian", "pizza": "italian", "mediterranean": "italian",
    "japanese": "asian", "sushi": "asian", "ramen": "asian", "thai": "asian", "vietnamese": "asian",
    "chinese": "asian", "korean": "asian", "asian": "asian", "indian": "asian",
    "burger": "burger", "american": "burger", "kebab": "burger",
}

COMMENTS = {
    "good": ["Super miejsce, na pewno wrócę.", "Bardzo miła obsługa i świetny klimat.",
             "Idealne miejsce na spotkanie ze znajomymi.", "Wszystko pyszne, ceny w porządku.",
             "Dobre miejsce, żeby posiedzieć z laptopem.", "Jedno z moich ulubionych miejsc w okolicy."],
    "mixed": ["Jedzenie dobre, ale trzeba było długo czekać.", "W porządku, choć w weekendy bywa bardzo tłoczno.",
              "Fajny klimat, trochę za głośno jak na pracę.", "Ceny nieco wysokie, ale jakość się zgadza."],
    "bad": ["Długo czekaliśmy, a jedzenie było zimne.", "Za głośno i za ciasno.", "Obsługa niezbyt uprzejma."],
}


def amenity(kind: str, flag: str, rng: random.Random) -> bool:
    return rng.random() < AMENITY_ODDS[kind][flag]


def opening_hours(kind: str, rng: random.Random) -> OpeningHours:
    schedule = rng.choice(HOURS[kind])
    return OpeningHours(
        periods=[
            OpeningPeriod(day=day, open=open_, close=close)
            for first, last, open_, close in schedule
            for day in range(first, last + 1)
        ]
    )


def usage_price(kind: str, rng: random.Random) -> str:
    if kind == "cafe":
        return rng.choices(["0-30", "30-60"], weights=[85, 15])[0]
    return rng.choices(["0-30", "30-60", "60-90"], weights=[20, 55, 25])[0]


def atmosphere(kind: str, rng: random.Random) -> Atmosphere:
    weights = [45, 45, 10] if kind == "cafe" else [15, 55, 30]
    return rng.choices(list(Atmosphere), weights=weights)[0]


def features(kind: str, rng: random.Random) -> list[str]:
    return rng.sample(FEATURES[kind], k=rng.randint(1, 3))


def menu(kind: str, cuisines: list[str], rng: random.Random) -> list[MenuItem]:
    if kind == "cafe":
        pool = MENUS["cafe"]
    else:
        pool = MENUS[next((CUISINE_MENU[c] for c in cuisines if c in CUISINE_MENU), "polish")]
    items = rng.sample(pool, k=min(len(pool), rng.randint(4, 7)))
    return [
        MenuItem(category=category, name=name, price=rng.randint(low, high) * 100)
        for category, name, low, high in items
    ]


def reviews(rng: random.Random) -> list[tuple[str, int, str | None]]:
    """(mock user id, score 1-5, comment or None) – a handful of reviews per place."""
    users = rng.sample([f"mock-user-{i:02d}" for i in range(1, 21)], k=rng.choice([0, 1, 2, 3, 3, 4, 5, 6]))
    result = []
    for user in users:
        score = rng.choices([1, 2, 3, 4, 5], weights=[4, 8, 18, 38, 32])[0]
        mood = "good" if score >= 4 else "mixed" if score == 3 else "bad"
        comment = rng.choice(COMMENTS[mood]) if rng.random() < 0.6 else None
        result.append((user, score, comment))
    return result
