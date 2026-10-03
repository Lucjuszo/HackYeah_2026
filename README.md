# HackYeah_2026

Backend: FastAPI + MongoDB (pymongo async).

## Uruchomienie

```bash
pip install -r requirements.txt
cp .env.example .env                      # i uzupełnij dane do bazy
fastapi dev app/main.py                   # http://127.0.0.1:8000/docs
```

Healthcheck: `GET /health`. Konfiguracja w `.env` (patrz `.env.example`).

### Baza danych

Domyślnie backend łączy się ze zdalnym MongoDB (Atlas) z `MONGODB_URI`.
Lokalny Mongo w kontenerze:

```bash
docker compose up -d                      # MongoDB na localhost:27017 (root / example)
# w .env:
USE_REMOTE_MONGO=false
```

### Logowanie

GitHub i Google przez OAuth; backend wystawia własny token (`Authorization: Bearer ...`).
Odczyt publiczny, zapis wymaga logowania; komentarze edytuje/usuwa autor albo admin.
Konfiguracja i testowanie bez frontu: [`docs/AUTH.md`](docs/AUTH.md).

### Integracja z frontem

CORS, logowanie, wyszukiwanie, zdjęcia, paginacja, błędy: [`docs/FRONTEND.md`](docs/FRONTEND.md).

### Dane testowe

```bash
python scripts/import_osm.py              # 30 prawdziwych kawiarni i restauracji z Krakowa (OSM) + dane mock
python scripts/seed.py                    # albo 6 wymyślonych miejsc z examples/places/
```

Oba piszą do bazy wybranej w `.env` i oznaczają wszystko `is_mock: true`; przed startem usuwają
**wszystkie** poprzednie dane mock (prawdziwych nie ruszają). Przy imporcie z OSM nazwa, adres,
współrzędne, godziny i tagi OSM są prawdziwe, a `mock_fields` wymienia pola wymyślone.
Dane OSM są w repo jako snapshot (`data/osm/`, © OpenStreetMap contributors, ODbL);
`--refresh` pobiera świeże z Overpass API.
Usunięcie danych mock w Compass: filtr `{ "is_mock": true }` w kolekcjach `places`, `ratings`, `comments`.

### Przykłady

- curl: [`examples/README.md`](examples/README.md)
- Postman: [`postman/README.md`](postman/README.md)

## Testy

```bash
docker compose up -d
pip install -r requirements-dev.txt
pytest
```

Testy zawsze używają kontenera (baza `hackyeah_test`, usuwana po testach), niezależnie od `.env`.
