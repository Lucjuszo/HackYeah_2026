# Kolekcja Postmana

`HackYeah.postman_collection.json` – 75 zapytań z testami, ułożone w scenariusz:

| Folder | Co robi |
|---|---|
| `0. Auth` | jawne logowanie (opcjonalne – patrz niżej), `me`, błędne tokeny, podgląd przekierowania OAuth |
| `CORS preflight` (×2) | to, co przeglądarka wysyła przed zapytaniem z frontu: z `localhost:5173` i z losowego portu (Flutter web) |
| `1. Places` | dodanie, odczyt, `/places/summary` (mapa, `bbox` = widoczny obszar), `/geocode` (wybór miasta), wyszukiwanie (dystans, `q`, `wifi`, `atmosphere`, `open_now`, ceny `min_price`/`max_price`, `sort`, `X-Total-Count`, `closes_at`/`opens_at`), edycje częściowe (merge `amenities`, czyszczenie `null`, link do OSM, edycja przez innego użytkownika), błędy 401/404/422 |
| `2. Ratings` | `anna` 5 → `bartek` 3 → `anna` zmienia na 4 → usuwa; testy sprawdzają średnią na każdym kroku |
| `3. Comments` | autor edytuje, inny użytkownik dostaje 403, admin edytuje i usuwa |
| `4. Photos` | upload (wersja pełna ≤1600 px + miniatura ≤400 px, WebP), lista, metadane, pobranie pliku (`/file?size=full\|thumbnail&download=true` i adres `/media/...`), 401/403/404, usunięcie własnego |
| `5. Delete place (admin)` | na koniec: 403 dla zwykłego usera, admin usuwa miejsce razem z ocenami, komentarzami i zdjęciami |

## Start

1. Backend z `AUTH_DEV_LOGIN=true` i `JWT_SECRET` w `.env`, `fastapi dev app/main.py`.
2. Postman → **Import** → `HackYeah.postman_collection.json`.
3. Wyślij dowolne zapytanie. **Logowanie dzieje się samo**: przed pierwszym zapytaniem kolekcja loguje
   trzech testowych użytkowników przez `/auth/dev-login` i zapamiętuje ich tokeny:

   | Użytkownik | Rola | Zmienna z tokenem |
   |---|---|---|
   | `anna` | user (domyślny dla wszystkich zapytań) | `token` |
   | `bartek` | user (do testów „cudzy komentarz”) | `tokenOther` |
   | `boss` | admin | `adminToken` |

   Logi logowania widać w Postman → **Console** (na dole okna).
4. Foldery uruchamiaj po kolei (zapisują `placeId`, `commentId`, ... dla kolejnych) albo całość: kolekcja → **Run**.
5. `4. Photos` wysyła `postman/sample-photo.jpg`. Postman szuka pliku względem *Settings → General → Working directory*
   – ustaw tam katalog repo albo w *Upload photo* → *Body* → pole `file` wybierz dowolny obrazek.

Jeśli API nie jest na `http://localhost:8000`: kolekcja → *Variables* → `baseUrl`.

**Coś zwraca 401?** Np. po zmianie `JWT_SECRET` stare tokeny przestają działać. Kolekcja sama je wtedy
czyści – po prostu wyślij zapytanie jeszcze raz. Ręcznie: wyczyść zmienne `token`, `tokenOther`, `adminToken`.

## Prawdziwe logowanie (GitHub / Google) zamiast dev-login

Zmienna kolekcji `autoLogin` → `off`. Otwórz w przeglądarce `http://localhost:8000/auth/github/login`
(albo `/google/login`), zaloguj się, skopiuj `access_token` z JSON-a do zmiennej `token`.
Konfiguracja aplikacji OAuth: [`docs/AUTH.md`](../docs/AUTH.md).

## Aktualizacja kolekcji

Postman **nie śledzi pliku** – import robi kopię w aplikacji. Po zmianach w repo: **Import** tego samego
pliku → Postman rozpozna kolekcję (stałe ID) i zaproponuje **Replace**. Uwaga: Replace nadpisuje zmiany
zrobione w aplikacji (własne zapytania dopisuj w osobnej kolekcji albo przenieś je potem do repo).

## Z linii poleceń

```bash
npx newman run postman/HackYeah.postman_collection.json --env-var baseUrl=http://localhost:8000 \
  --folder "1. Places" --folder "2. Ratings" --folder "3. Comments" --folder "4. Photos" --folder "5. Delete place (admin)"
```
(uruchamiaj z katalogu repo – upload zdjęcia bierze `postman/sample-photo.jpg` ze ścieżki względnej)
