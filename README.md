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

### Dane testowe

```bash
python scripts/seed.py                    # do bazy wybranej w .env
```

Wrzuca przykładowe miejsca z `examples/places/` z ocenami i komentarzami, wszystko z `is_mock: true`.
Można go uruchamiać wielokrotnie: najpierw usuwa poprzednie dane mock, prawdziwych nie rusza.
Usunięcie danych mock w Compass: filtr `{ "is_mock": true }` w kolekcjach `places`, `ratings`, `comments`.

Przykłady zapytań (curl): [`examples/README.md`](examples/README.md).

## Testy

```bash
docker compose up -d
pip install -r requirements-dev.txt
pytest
```

Testy zawsze używają kontenera (baza `hackyeah_test`, usuwana po testach), niezależnie od `.env`.
