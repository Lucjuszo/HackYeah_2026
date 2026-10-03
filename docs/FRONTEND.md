# Integracja z frontem

Front: Flutter (`frontend/`). Kontrakt API: `http://localhost:8000/docs` (Swagger) i `/openapi.json`.

- Adres API do aplikacji przez `--dart-define`, nie na sztywno w kodzie:
  `flutter run -d chrome --dart-define=API_URL=http://localhost:8000`
  → `const apiUrl = String.fromEnvironment('API_URL', defaultValue: 'http://localhost:8000');`
- Flutter web (Chrome): CORS przepuszcza każdy port `localhost` (`CORS_ALLOW_LOCALHOST`).
  Aplikacja Windows (`flutter run -d windows`): CORS jej nie dotyczy.
- Daty (`created_at`, `closes_at`, ...) to ISO 8601 z offsetem → `DateTime.parse(...).toLocal()`.
- Opcjonalnie klient Dart z OpenAPI: `npx @openapitools/openapi-generator-cli generate -i http://localhost:8000/openapi.json -g dart -o frontend/api_client`.

## Konfiguracja backendu (`.env`)

| Zmienna | Przykład | Po co |
|---|---|---|
| `CORS_ORIGINS` | `https://app.example.com` | adresy frontu, które mogą wołać API z przeglądarki |
| `CORS_ALLOW_LOCALHOST` | `true` (domyślnie) | dodatkowo `localhost` / `127.0.0.1` na **dowolnym porcie** – `flutter run -d chrome` losuje port. Na produkcji `false` |
| `PUBLIC_BASE_URL` | `http://localhost:8000` | adresy zdjęć stają się pełne (`http://localhost:8000/media/...`); bez tego są względne `/media/...` |
| `AUTH_REDIRECT_URL` | `http://localhost:5173/auth/callback` | strona frontu, na którą wraca logowanie OAuth |
| `AUTH_DEV_LOGIN` | `true` | lokalnie: logowanie bez OAuth (`POST /auth/dev-login`) |

## Logowanie

1. `GET /auth/providers` → `{providers: [{name, login_url}], dev_login}`.
2. Przycisk „Zaloguj przez GitHub” = **nawigacja całej strony** na `login_url` (nie `fetch`).
3. Backend wraca na `AUTH_REDIRECT_URL#access_token=...&expires_in=86400`. Front czyta `location.hash`,
   zapisuje token, czyści adres (`history.replaceState`).
4. Każde zapytanie zapisujące: nagłówek `Authorization: Bearer <token>`. Bez cookies (`credentials` niepotrzebne).
5. `GET /auth/me` → profil (imię, avatar, rola `user`/`admin`).
6. **`401` = token wygasł lub jest zły** (żyje 24 h, odświeżania nie ma): usuń token i pokaż logowanie.

Lokalnie bez OAuth: `POST /auth/dev-login` z `{"name": "anna", "role": "user"}` → ten sam `access_token`.
**Na start integracji polecane** – działa identycznie w Chrome i w aplikacji Windows.

Kroki 2–3 (przekierowania) działają we Flutter web. W aplikacji Windows nie ma paska adresu, do którego
backend mógłby wrócić – tam OAuth wymaga osobnego rozwiązania (np. `AUTH_REDIRECT_URL=http://localhost:<port>/`
nasłuchiwany przez aplikację); do ustalenia, jeśli wersja desktopowa będzie potrzebna.

## Miejsca

| Endpoint | Do czego |
|---|---|
| `GET /places/summary` | **pinezki na mapie i karty na liście**: lekkie rekordy, `thumbnail_url`, `open_now`, `photo_count`, do 1000 na stronę |
| `GET /places` | pełne rekordy (menu, godziny, wszystkie zdjęcia), do 200 na stronę |
| `GET /places/{id}` | strona miejsca |
| `POST /places`, `PATCH /places/{id}` | dodanie / edycja (zalogowany) |
| `DELETE /places/{id}` | tylko admin; usuwa też oceny, komentarze i zdjęcia |

Parametry wyszukiwania (te same dla `/places` i `/places/summary`):

| Parametr | Opis |
|---|---|
| `bbox` | `south,west,north,east` – **widoczny obszar mapy**, dowolnej wielkości (od ulicy po całą Polskę). Zamiast `lat`/`lon` |
| `lat`, `lon`, `radius_m` | w promieniu (domyślnie 1000 m, max 50 km); odpowiedź ma `distance_m`; potrzebne do `sort=distance` |
| `q` | fragment nazwy lub ulicy, bez rozróżniania wielkości liter |
| `wifi`, `power_outlets` | `true` / `false` |
| `atmosphere` | `quiet` / `chatty` / `lively` |
| `min_rating` | 1–5 |
| `min_price`, `max_price` | PLN, po `price_range` (patrz niżej) |
| `open_now` | `true` = otwarte teraz (czas `Europe/Warsaw`); miejsca bez godzin pomijane |
| `sort` | `distance` (domyślne z `lat`/`lon`), `rating`, `name`, `newest`, `oldest` (domyślne bez punktu) |
| `limit`, `skip` | paginacja |

**Paginacja:** łączna liczba wyników jest w nagłówku `X-Total-Count` (`/places`, `/places/summary`,
`/places/{id}/comments`). CORS go udostępnia: `Number(res.headers.get("X-Total-Count"))`.

Godziny w `/places/summary`:

| Pole | Znaczenie |
|---|---|
| `open_now` | `true` / `false` / `null` (godziny nieznane) |
| `closes_at` | gdy otwarte: koniec bieżącego otwarcia, np. `2026-10-07T20:00:00+02:00` → „Otwarte do 20:00”; `null` = non-stop |
| `opens_at` | gdy zamknięte: najbliższe otwarcie w ciągu tygodnia → „Zamknięte, otwiera o 9:00” / „w pon. 9:00” |

Godziny po północy (np. pt 20:00–sob 02:00) są liczone jako jedno otwarcie.

### Ceny

`usage_price` to tekst wpisany przez użytkownika (`"0-30"`, `"60+"`, `"za darmo"`). Backend wylicza z niego
`price_range: {min, max}` w PLN (`max: null` = „od X wzwyż”; `price_range: null`, gdy tekstu nie da się
odczytać, np. „tanio” – takie miejsca nie łapią się w filtry cen). Filtry:

| Chip na froncie | Parametry |
|---|---|
| Bezpłatne | `max_price=0` |
| Do 30 zł | `max_price=30` |
| Powyżej 30 zł | `min_price=30` |

## Wybór lokalizacji (`GET /geocode`)

`GET /geocode?q=Gdańsk` → `[{name, display_name, lat, lon, kind, bbox: [south, north, west, east]}]` – miasta, dzielnice
i adresy w Polsce (OpenStreetMap Nominatim przez backend: wymagany User-Agent, limit 1 zapytanie/s i cache po stronie
backendu, dlatego front nie woła Nominatim bezpośrednio). Bez logowania. `503` = wyszukiwarka adresów chwilowo niedostępna.

## Zdjęcia

- Upload: `POST /places/{id}/photos`, `multipart/form-data`, pole `file` (JPEG/PNG/WebP/GIF/BMP, max 10 MB).
  Nie ustawiaj ręcznie `Content-Type` – przeglądarka doda `boundary` sama przy `FormData`.
- Odpowiedź: `url` (pełna wersja ≤1600 px) i `thumbnail.url` (≤400 px), plus wymiary – można zarezerwować
  miejsce w layoucie (`width`/`height` w `<img>`), zanim obrazek się wczyta.
- `url` wkładasz prosto w `<img src>` (z `PUBLIC_BASE_URL` jest pełny). Pliki są publiczne i cache'owane na zawsze.
- Pobranie jako plik: `GET /places/{id}/photos/{photo_id}/file?size=full|thumbnail&download=true`.
- Usunąć może autor (`uploaded_by`) albo admin. `uploaded_by_name` = podpis „dodał(a)”.

## Błędy

Zawsze JSON `{"detail": ...}`:

| Kod | Kiedy | Co zrobić na froncie |
|---|---|---|
| 401 | brak / wygasły token | wylogować, pokazać logowanie |
| 403 | cudzy komentarz / zdjęcie, usuwanie miejsca bez admina | ukryć przycisk (porównaj `user.id`, `role`) |
| 404 | nie ma takiego zasobu | |
| 409 | limit 20 zdjęć na miejsce, miejsce z tym OSM już istnieje | komunikat z `detail` |
| 413 / 415 | za duży plik / to nie obrazek | komunikat przy uploadzie |
| 422 | walidacja; `detail` to **lista** `{loc, msg}` | podświetlić pola z `loc` |
| 429 | limit: 30 zdjęć / 60 komentarzy na godzinę na użytkownika | nagłówek `Retry-After` (sekundy) |
| 503 | `/health`: baza niedostępna | |
