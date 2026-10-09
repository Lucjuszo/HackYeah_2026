# Integracja z frontem

Front: Flutter (`frontend/`). Kontrakt API: `http://localhost:8000/docs` (Swagger) i `/openapi.json`.

- Adres API do aplikacji przez `--dart-define`, nie na sztywno w kodzie:
  `flutter run -d chrome --dart-define=API_URL=http://localhost:8000`
  → `const apiUrl = String.fromEnvironment('API_URL', defaultValue: 'http://localhost:8000');`
- Flutter web (Chrome): CORS przepuszcza każdy port `localhost` (`CORS_ALLOW_LOCALHOST`).
  Aplikacja Windows (`flutter run -d windows`): CORS jej nie dotyczy.
- Android nie używa CORS, ale `localhost` wskazuje na urządzenie Android. Emulator używa
  `10.0.2.2`, a telefon fizyczny wymaga adresu LAN komputera przekazanego przez
  `--dart-define=API_URL=http://IP_KOMPUTERA:8000`.
- Daty (`created_at`, `closes_at`, ...) to ISO 8601 z offsetem → `DateTime.parse(...).toLocal()`.
- Opcjonalnie klient Dart z OpenAPI: `npx @openapitools/openapi-generator-cli generate -i http://localhost:8000/openapi.json -g dart -o frontend/api_client`.

## Konfiguracja backendu (`.env`)

| Zmienna | Przykład | Po co |
|---|---|---|
| `CORS_ORIGINS` | `https://app.example.com` | adresy frontu, które mogą wołać API z przeglądarki |
| `CORS_ALLOW_LOCALHOST` | `true` (domyślnie) | dodatkowo `localhost` / `127.0.0.1` na **dowolnym porcie** – `flutter run -d chrome` losuje port. Na produkcji `false` |
| `PUBLIC_BASE_URL` | `http://localhost:8000` | adresy zdjęć stają się pełne (`http://localhost:8000/media/...`); bez tego są względne `/media/...` |
| `OAUTH_CALLBACK_BASE_URL` | `http://localhost:8000` | publiczny adres API używany jako baza callbacku GitHub/Google; na telefonie ustaw adres LAN komputera |
| `AUTH_REDIRECT_URL` | `http://localhost:5173/auth/callback` | strona frontu, na którą wraca logowanie OAuth |
| `AUTH_DEV_LOGIN` | `true` | lokalnie: logowanie bez OAuth (`POST /auth/dev-login`) |

## Logowanie (GitHub / Google)

Front loguje dopiero, gdy jest potrzebne (dodanie miejsca, ocena, opinia): arkusz „Zaloguj się” z przyciskami
dostawców z `GET /auth/providers` (użytkownik wybiera GitHub albo Google). Token trzyma między uruchomieniami
(`shared_preferences`), a `GET /auth/me` mówi, kto jest zalogowany (własne opinie można edytować i usuwać). Cały OAuth robi backend, front tylko otwiera stronę logowania i odbiera token:

- **Flutter web:** wyskakujące okno na `GET /auth/{github|google}/login?return_to=<origin frontu>/auth_callback.html`.
  Backend po zalogowaniu odsyła okno na `return_to#access_token=...&expires_in=...` (albo `#error=access_denied`),
  a `web/auth_callback.html` przekazuje token do aplikacji (postMessage + localStorage) i zamyka okno.
  Okno musi otworzyć się bezpośrednio po kliknięciu, inaczej przeglądarka je zablokuje.
- **Windows:** systemowa przeglądarka; `return_to=http://127.0.0.1:<losowy port>/callback` to jednorazowa strona
  serwowana przez aplikację.

`return_to` musi mieć origin z `CORS_ORIGINS`, z `AUTH_REDIRECT_URL` albo – przy `CORS_ALLOW_LOCALHOST=true` –
`localhost`/`127.0.0.1` na dowolnym porcie; inaczej `400`. Bez `return_to` backend wraca na `AUTH_REDIRECT_URL`,
a bez obu odpowiada JSON-em (testy bez frontu).

Każde zapytanie zapisujące: `Authorization: Bearer <token>`. **`401` = token wygasł** (24 h): front zapomina
token, następna akcja loguje od nowa. Lokalnie bez Google: `POST /auth/dev-login` (`AUTH_DEV_LOGIN=true`).

Konfiguracja klienta Google (Cloud Console, redirect URI `http://localhost:8000/auth/google/callback`):
[`AUTH.md`](AUTH.md), sekcja *Google*.

## Dodawanie miejsca, ocen i opinii

- **Miejsce** (przycisk + na liście → formularz „Dodaj miejsce”): nazwa, pinezka na mapie (adres z
  `GET /geocode/reverse`, `404` = brak adresu), wyszukiwanie adresu (`GET /geocode`), kategoria (`category`:
  `cafe`, `library`, `coworking`, `restaurant`, `park`, `other`; filtr `?category=` w wyszukiwaniu), udogodnienia,
  atmosfera, cena (`usage_price`: `za darmo`, `0-30`, `30-60`, `60+`) i godziny otwarcia (nie wiem / całą dobę /
  własne). Potem `POST /places` i od razu szczegóły nowego miejsca.
- **Ocena** (szczegóły → karta „Twoja opinia”, gwiazdki): `GET/PUT/DELETE /places/{id}/ratings/me`; PUT zwraca nowe
  podsumowanie (`summary`), które front od razu pokazuje.
- **Opinie**: `POST /places/{id}/comments` (komentarz w tej samej karcie; `score` 1–5 jest **obowiązkowy**, bez niego `422`),
  `PATCH` / `DELETE .../comments/{id}` z menu ⋮ przy własnych opiniach (admin: przy wszystkich). Każda opinia ma
  `user_score` – aktualną ocenę miejsca wystawioną przez autora (zmienia się razem z oceną).
- **Łapki w górę**: `PUT` / `DELETE /places/{id}/comments/{id}/like` (jedna na użytkownika, bez łapek w dół).
  `GET .../comments` zwraca najpierw opinie z największą liczbą łapek (`likes`, `liked_by`), potem najnowsze.

## Miejsca

| Endpoint | Do czego |
|---|---|
| `GET /places/summary` | **pinezki na mapie i karty na liście**: lekkie rekordy, `thumbnail_url`, `open_now`, `photo_count`, do 1000 na stronę |
| `GET /places` | pełne rekordy (menu, godziny, wszystkie zdjęcia), do 200 na stronę |
| `GET /places/{id}` | strona miejsca |
| `POST /places`, `PATCH /places/{id}` | dodanie / edycja (zalogowany) |
| `DELETE /places/{id}` | tylko admin; usuwa też oceny, komentarze i zdjęcia |
| `GET /admin/places?approved=false` | tylko admin; miejsca czekające na akceptację (`true` = publiczne), najnowsze pierwsze, `q`, `limit`, `skip`, `X-Total-Count` |
| `PUT /admin/places/{id}/approval` | tylko admin; `{"approved": true}` publikuje, `false` ukrywa z powrotem |

Nowe miejsce od zwykłego użytkownika ma `approved: false`: nie ma go w wyszukiwaniach, a `GET /places/{id}`
zwraca je tylko autorowi i adminom (z tokenem), innym 404. Miejsca admina są publiczne od razu.
Wyłączenie akceptacji: `PLACES_REQUIRE_APPROVAL=false`.

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
- `url` wkładasz prosto w `<img src>`: na produkcji to adres CDN Cloudinary (`https://res.cloudinary.com/...`),
  lokalnie `/media/...` (z `PUBLIC_BASE_URL` pełny). Pliki są publiczne i cache'owane na zawsze.
- Pobranie jako plik: `GET /places/{id}/photos/{photo_id}/file?size=full|thumbnail&download=true`
  (przy Cloudinary: przekierowanie 307 na CDN).
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
