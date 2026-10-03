# Kolekcja Postmana

`HackYeah.postman_collection.json` – 43 zapytania z testami, ułożone w scenariusz:

| Folder | Co robi |
|---|---|
| `0. Auth` | jawne logowanie (opcjonalne – patrz niżej), `me`, błędne tokeny, podgląd przekierowania OAuth |
| `1. Places` | dodanie, odczyt, wyszukiwanie, edycje częściowe (merge `amenities`, czyszczenie `null`, link do OSM, edycja przez innego użytkownika), błędy 401/404/422 |
| `2. Ratings` | `anna` 5 → `bartek` 3 → `anna` zmienia na 4 → usuwa; testy sprawdzają średnią na każdym kroku |
| `3. Comments` | autor edytuje, inny użytkownik dostaje 403, admin edytuje i usuwa |
| `4. Photos` | upload, pobranie pliku, 403 dla cudzego zdjęcia, usunięcie własnego |

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
5. Przed `4. Photos`: w *Upload photo* → *Body* → pole `file` → wybierz dowolny obrazek.

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
  --folder "1. Places" --folder "2. Ratings" --folder "3. Comments"
```
(upload zdjęcia wymaga wskazania pliku, dlatego w CLI najprościej pominąć `4. Photos`)
