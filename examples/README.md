# Przykłady zapytań API

Wszystkie przykłady zakładają API na `http://localhost:8000`. Uruchomienie:

```bash
fastapi dev app/main.py    # baza z .env: domyślnie zdalna (Atlas); USE_REMOTE_MONGO=false + docker compose up -d dla lokalnej
```

Interaktywna dokumentacja (Swagger): http://localhost:8000/docs

> **Windows / PowerShell:** wpisuj `curl.exe` zamiast `curl`, bo samo `curl` to alias
> `Invoke-WebRequest`. Wszystkie body są w plikach (`-d @plik.json`), więc nie trzeba
> walczyć z cudzysłowami. Komendy uruchamiaj z katalogu głównego repo.

`<PLACE_ID>`, `<PHOTO_ID>` i `<COMMENT_ID>` podmień na ID z odpowiedzi poprzednich zapytań.

## Dane testowe

Skrypt wrzuca bezpośrednio do bazy wszystkie miejsca z `examples/places/` razem z ocenami
i komentarzami od kilku użytkowników (`anna`, `bartek`, `celina`, `dawid`, `ewa`).
Wszystko dostaje `is_mock: true`; ponowne uruchomienie podmienia dane mock, prawdziwych nie rusza.

```bash
python scripts/seed.py                       # baza wybrana w .env
```

| Plik | Co pokazuje |
|---|---|
| `01-kawiarnia-pod-kodem.json` | komplet pól, godziny przez północ w piątek, duże menu |
| `02-czytelnia-kazimierz.json` | cicha czytelnia z dostępem do komputera, bez jedzenia |
| `03-cowork-hub-zablocie.json` | całodobowy cowork (`always_open`), płatny wstęp `30-60` |
| `04-nocna-stolowka.json` | otwarte tylko w nocy, przedziały rozbite o północy |
| `05-antykwariat-i-kawa.json` | niepełne dane: większość udogodnień nieznana (`null`) |
| `06-kawiarnia-na-powislu.json` | Warszawa, do testowania filtra odległości |

## Użytkownik (mock)

Na razie nie ma logowania. Użytkownika podajesz w nagłówku `X-User-Id`
(litery, cyfry, `_`, `.`, `-`, maks. 64 znaki). Bez nagłówka API przyjmuje `mock-user-1`.
Nagłówek ustala autora miejsca, autora edycji, oceny i komentarza.

```bash
curl -H "X-User-Id: anna" ...
```

---

## Miejsca

### Dodanie miejsca
```bash
curl -X POST http://localhost:8000/places \
  -H "Content-Type: application/json" \
  -H "X-User-Id: anna" \
  -d @examples/places/01-kawiarnia-pod-kodem.json
```
`201`, w odpowiedzi całe miejsce z `id`. `409`, jeśli miejsce z tym samym `osm` już istnieje.

### Pobranie miejsca
```bash
curl http://localhost:8000/places/<PLACE_ID>
```

### Lista / wyszukiwanie
```bash
# wszystkie (domyślnie 50)
curl "http://localhost:8000/places"

# w promieniu 1 km od Rynku w Krakowie, od najbliższego
curl "http://localhost:8000/places?lat=50.0617&lon=19.9373&radius_m=1000"

# z gniazdkami, druga strona po 10
curl "http://localhost:8000/places?power_outlets=true&limit=10&skip=10"
```

### Edycja miejsca (PATCH)
```bash
curl -X PATCH http://localhost:8000/places/<PLACE_ID> \
  -H "Content-Type: application/json" \
  -H "X-User-Id: bartek" \
  -d @examples/requests/place-update.json
```
Zasady:
- pole pominięte zostaje bez zmian,
- `null` czyści pole (tylko `opening_hours`, `usage_price`, `atmosphere`, `osm`),
- `amenities` łączy się pole po polu, więc `{"amenities": {"wifi": true}}` nie rusza pozostałych,
- `address`, `opening_hours`, `features` i `menu` są podmieniane w całości.

W odpowiedzi `updated_by` i `updated_at` wskazują, kto i kiedy edytował.

---

## Zdjęcia

```bash
# dodanie (multipart; JPEG/PNG/WebP/GIF do 10 MB, max 20 na miejsce)
curl -X POST http://localhost:8000/places/<PLACE_ID>/photos -F "file=@kawa.jpg"

# podgląd: pole "url" z odpowiedzi, np.
curl -O http://localhost:8000/media/places/<PLACE_ID>/<PHOTO_ID>.webp

# usunięcie
curl -X DELETE http://localhost:8000/places/<PLACE_ID>/photos/<PHOTO_ID>
```

---

## Oceny (1–5)

Każdy użytkownik ma jedną ocenę na miejsce. Ponowne `PUT` ją podmienia.
Średnia (`rating.average`) i liczba ocen (`rating.count`) są w każdym miejscu
i przeliczają się przy każdej zmianie.

```bash
# wystawienie / zmiana własnej oceny
curl -X PUT http://localhost:8000/places/<PLACE_ID>/ratings/me \
  -H "Content-Type: application/json" \
  -H "X-User-Id: anna" \
  -d @examples/requests/rating.json

# moja ocena
curl http://localhost:8000/places/<PLACE_ID>/ratings/me -H "X-User-Id: anna"

# podsumowanie: {"average": 4.5, "count": 2}
curl http://localhost:8000/places/<PLACE_ID>/ratings

# usunięcie własnej oceny
curl -X DELETE http://localhost:8000/places/<PLACE_ID>/ratings/me -H "X-User-Id: anna"
```

---

## Komentarze

```bash
# dodanie
curl -X POST http://localhost:8000/places/<PLACE_ID>/comments \
  -H "Content-Type: application/json" \
  -H "X-User-Id: anna" \
  -d @examples/requests/comment.json

# lista, od najnowszych (domyślnie 20, max 100)
curl "http://localhost:8000/places/<PLACE_ID>/comments?limit=20&skip=0"

# usunięcie (tylko autor, inaczej 403)
curl -X DELETE http://localhost:8000/places/<PLACE_ID>/comments/<COMMENT_ID> -H "X-User-Id: anna"
```

---

## Kody odpowiedzi

| Kod | Kiedy |
|---|---|
| `200` / `201` / `204` | OK / utworzono / usunięto |
| `403` | próba usunięcia cudzego komentarza |
| `404` | nie ma miejsca, zdjęcia, komentarza lub oceny |
| `409` | konflikt: zajęty link do OSM albo limit zdjęć |
| `413` / `415` | zdjęcie za duże / to nie jest obrazek |
| `422` | błędne dane; szczegóły w `detail` |
