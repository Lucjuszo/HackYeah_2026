# Przykłady zapytań API

Wszystkie przykłady zakładają API na `http://localhost:8000`. Uruchomienie:

```bash
fastapi dev app/main.py    # baza z .env: domyślnie zdalna (Atlas); USE_REMOTE_MONGO=false + docker compose up -d dla lokalnej
```

Interaktywna dokumentacja (Swagger): http://localhost:8000/docs. Przycisk **Authorize** przyjmuje token.
Gotowa kolekcja Postmana: [`postman/`](../postman/README.md).

> **Windows / PowerShell:** wpisuj `curl.exe` zamiast `curl`, bo samo `curl` to alias
> `Invoke-WebRequest`. Wszystkie body są w plikach (`-d @plik.json`), więc nie trzeba
> walczyć z cudzysłowami. Komendy uruchamiaj z katalogu głównego repo.

`<TOKEN>`, `<PLACE_ID>`, `<PHOTO_ID>` i `<COMMENT_ID>` podmień na wartości z odpowiedzi poprzednich zapytań.

## Dane testowe

```bash
python scripts/import_osm.py     # 30 prawdziwych kawiarni i restauracji z Krakowa (OSM) + dane mock
python scripts/seed.py           # albo: 6 wymyślonych miejsc z examples/places/
```

Oba skrypty piszą do bazy wybranej w `.env`, oznaczają wszystko `is_mock: true` i przed startem
usuwają **wszystkie** poprzednie dane mock (prawdziwych nie ruszają) – działa więc ten uruchomiony jako ostatni.
Przy imporcie z OSM pole `mock_fields` mówi, które dane są wymyślone (np. `menu`, `amenities.wifi`);
reszta (nazwa, adres, współrzędne, godziny, udogodnienia z tagów OSM) jest prawdziwa.
Dane mapy © OpenStreetMap contributors, licencja ODbL.

| Plik w `examples/places/` | Co pokazuje |
|---|---|
| `01-kawiarnia-pod-kodem.json` | komplet pól, godziny przez północ w piątek, duże menu |
| `02-czytelnia-kazimierz.json` | cicha czytelnia z dostępem do komputera, bez jedzenia |
| `03-cowork-hub-zablocie.json` | całodobowy cowork (`always_open`), płatny wstęp `30-60` |
| `04-nocna-stolowka.json` | otwarte tylko w nocy, przedziały rozbite o północy |
| `05-antykwariat-i-kawa.json` | niepełne dane: większość udogodnień nieznana (`null`) |
| `06-kawiarnia-na-powislu.json` | Warszawa, do testowania filtra odległości |

---

## Logowanie

Odczyt jest publiczny. Wszystko, co zapisuje (dodawanie, edycja, oceny, komentarze, zdjęcia),
wymaga tokena w nagłówku:

```bash
-H "Authorization: Bearer <TOKEN>"
```

Token zdobywasz na dwa sposoby (szczegóły i konfiguracja: [`docs/AUTH.md`](../docs/AUTH.md)):

```bash
# 1. Prawdziwe logowanie: otwórz w przeglądarce i zaloguj się – dostaniesz JSON z access_token
http://localhost:8000/auth/github/login
http://localhost:8000/auth/google/login

# 2. Lokalnie, bez OAuth (wymaga AUTH_DEV_LOGIN=true w .env)
curl -X POST http://localhost:8000/auth/dev-login -H "Content-Type: application/json" -d @examples/requests/dev-login-user.json
curl -X POST http://localhost:8000/auth/dev-login -H "Content-Type: application/json" -d @examples/requests/dev-login-admin.json
```

```bash
# kim jestem
curl http://localhost:8000/auth/me -H "Authorization: Bearer <TOKEN>"

# dostępne metody logowania
curl http://localhost:8000/auth/providers
```

---

## Miejsca

### Dodanie miejsca
```bash
curl -X POST http://localhost:8000/places \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <TOKEN>" \
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
Może każdy zalogowany; `updated_by` to ostatni edytujący (autor aktualnego opisu).
```bash
curl -X PATCH http://localhost:8000/places/<PLACE_ID> \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <TOKEN>" \
  -d @examples/requests/place-update.json
```
Zasady:
- pole pominięte zostaje bez zmian,
- `null` czyści pole (tylko `opening_hours`, `usage_price`, `atmosphere`, `osm`),
- `amenities` łączy się pole po polu – `{"amenities": {"wifi": true}}` nie rusza pozostałych,
- `address`, `opening_hours`, `features` i `menu` są podmieniane w całości,
- edytowane pole znika z `mock_fields` (od teraz to prawdziwa informacja).

---

## Zdjęcia

```bash
# dodanie (multipart; JPEG/PNG/WebP/GIF do 10 MB, max 20 na miejsce)
curl -X POST http://localhost:8000/places/<PLACE_ID>/photos -H "Authorization: Bearer <TOKEN>" -F "file=@kawa.jpg"

# podgląd: pole "url" z odpowiedzi, np.
curl -O http://localhost:8000/media/places/<PLACE_ID>/<PHOTO_ID>.webp

# usunięcie (tylko ten, kto wrzucił, albo admin)
curl -X DELETE http://localhost:8000/places/<PLACE_ID>/photos/<PHOTO_ID> -H "Authorization: Bearer <TOKEN>"
```

---

## Oceny (1–5)

Każdy użytkownik ma jedną ocenę na miejsce – ponowne `PUT` ją podmienia.
Średnia (`rating.average`) i liczba ocen (`rating.count`) są w każdym miejscu
i przeliczają się przy każdej zmianie.

```bash
# wystawienie / zmiana własnej oceny
curl -X PUT http://localhost:8000/places/<PLACE_ID>/ratings/me \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <TOKEN>" \
  -d @examples/requests/rating.json

# moja ocena
curl http://localhost:8000/places/<PLACE_ID>/ratings/me -H "Authorization: Bearer <TOKEN>"

# podsumowanie: {"average": 4.5, "count": 2}
curl http://localhost:8000/places/<PLACE_ID>/ratings

# usunięcie własnej oceny
curl -X DELETE http://localhost:8000/places/<PLACE_ID>/ratings/me -H "Authorization: Bearer <TOKEN>"
```

---

## Komentarze

```bash
# dodanie (autor = zalogowany użytkownik)
curl -X POST http://localhost:8000/places/<PLACE_ID>/comments \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <TOKEN>" \
  -d @examples/requests/comment.json

# lista, od najnowszych (domyślnie 20, max 100)
curl "http://localhost:8000/places/<PLACE_ID>/comments?limit=20&skip=0"

# edycja (tylko autor albo admin, inaczej 403)
curl -X PATCH http://localhost:8000/places/<PLACE_ID>/comments/<COMMENT_ID> \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <TOKEN>" \
  -d @examples/requests/comment-update.json

# usunięcie (tylko autor albo admin, inaczej 403)
curl -X DELETE http://localhost:8000/places/<PLACE_ID>/comments/<COMMENT_ID> -H "Authorization: Bearer <TOKEN>"
```

---

## Kody odpowiedzi

| Kod | Kiedy |
|---|---|
| `200` / `201` / `204` | OK / utworzono / usunięto |
| `400` | logowanie OAuth nie powiodło się (np. odmowa zgody) |
| `401` | brak tokena, zły albo wygasły token |
| `403` | zmiana cudzego komentarza lub zdjęcia bez roli admina |
| `404` | nie ma miejsca, zdjęcia, komentarza, oceny albo providera logowania |
| `409` | konflikt: zajęty link do OSM albo limit zdjęć |
| `413` / `415` | zdjęcie za duże / to nie jest obrazek |
| `422` | błędne dane – szczegóły w `detail` |
