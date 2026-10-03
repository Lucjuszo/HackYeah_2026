# HackYeah_2026

Backend: FastAPI + MongoDB (pymongo async).

## Uruchomienie

```bash
docker compose up -d                      # MongoDB na localhost:27017 (root / example)
pip install -r requirements.txt
fastapi dev app/main.py                   # http://127.0.0.1:8000/docs
```

Healthcheck: `GET /health`. Konfiguracja w `.env` (patrz `.env.example`).

Przykłady zapytań (curl) i dane testowe: [`examples/README.md`](examples/README.md).
Wrzucenie przykładowych miejsc z ocenami i komentarzami: `python scripts/seed.py`.

Testy: `pip install -r requirements-dev.txt && pytest` (wymaga Mongo z `docker compose up -d`).
