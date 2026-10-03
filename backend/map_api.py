"""Wyszukiwanie miejsc w OpenStreetMap (Overpass API).

pip install requests
python map_api.py
"""

import time

import requests

# Publiczne serwery Overpass - próbujemy po kolei, aż któryś odpowie
OVERPASS_URLS = [
    "https://overpass-api.de/api/interpreter",
    "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
]

HEADERS = {"User-Agent": "third-space"}


def search_places(
    place_type: str, lat: float, lon: float, radius: int = 1_000
) -> list[dict]:
    """Zwraca miejsca danego typu (np. "cafe") w promieniu `radius` metrów."""
    if not place_type.replace("_", "").isalpha():
        raise ValueError("Niepoprawny typ miejsca")

    area = f"(around:{radius},{lat},{lon})"
    query = f"""
    [out:json][timeout:25];
    (
      nwr["amenity"="{place_type}"]{area};
      nwr["shop"="{place_type}"]{area};
      nwr["tourism"="{place_type}"]{area};
      nwr["leisure"="{place_type}"]{area};
    );  
    out center;
    """

    for url in OVERPASS_URLS:
        start = time.time()
        try:
            # timeout=(10, 40): 10 s na połączenie, 40 s na odpowiedź
            response = requests.post(
                url, data={"data": query}, headers=HEADERS, timeout=(10, 40)
            )
            response.raise_for_status()
            places = response.json()["elements"]
            print(f"OK {url} ({time.time() - start:.1f} s)")
            return places
        except requests.RequestException as error:
            print(f"BŁĄD {url}: {type(error).__name__} ({time.time() - start:.1f} s)")

    raise ConnectionError("Żaden serwer Overpass nie odpowiedział") from None


if __name__ == "__main__":
    # test: kawiarnie 1 km od centrum Warszawy (mały promień = lekkie zapytanie)
    places = search_places("cafe", lat=52.2297, lon=21.0122, radius=500)

    print("Znaleziono:", len(places))
    for place in places[:5]:
        print(place)