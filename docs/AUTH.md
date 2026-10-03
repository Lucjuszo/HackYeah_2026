# Logowanie (OAuth: GitHub + Google)

## Jak to działa

```
przeglądarka ──► GET /auth/github/login ──► GitHub (zgoda) ──► GET /auth/github/callback?code=...
                                                                      │
                     backend: wymienia code na token GitHuba, pobiera profil,
                     zakłada / aktualizuje użytkownika w kolekcji `users`,
                     wystawia NASZ token (JWT) ◄──────────────────────────┘
                                       │
           AUTH_REDIRECT_URL ustawione │ nieustawione
       302 → frontend#access_token=... │ JSON { access_token, user, ... }
```

- Cały flow OAuth robi **backend**. Front niczego nie wie o GitHubie ani Google – tylko kieruje
  przeglądarkę na `/auth/{provider}/login` i odbiera token.
- Do API front wysyła **nasz** token: `Authorization: Bearer <access_token>`. Backend sprawdza
  podpis, wystawcę i datę ważności; ID użytkownika bierze z tokena, nie od frontu – nie da się go podrobić.
- Token ważny `JWT_TTL_MINUTES` (domyślnie 24 h). Nie ma odświeżania: po wygaśnięciu logowanie od nowa.
  Zmiana roli (np. odebranie admina) działa od następnego logowania.
- Użytkownik = konto u providera (`provider` + jego stałe ID użytkownika, nie e-mail). Ta sama osoba
  przez GitHub i przez Google to **dwa osobne konta** (łączenie kont to osobny temat).

### Kto co może

| Akcja | Kto |
|---|---|
| odczyt czegokolwiek | każdy, bez logowania |
| dodanie miejsca, edycja miejsca | każdy zalogowany; `updated_by` = ostatni edytujący |
| ocena | zalogowany, swoja (jedna na miejsce) |
| dodanie komentarza | zalogowany; autor = on |
| **edycja / usunięcie komentarza** | **autor albo admin** (inni: 403) |
| usunięcie zdjęcia | ten, kto je wrzucił, albo admin |

**Admin:** e-mail z listy `ADMIN_EMAILS` (zweryfikowany u providera) dostaje rolę `admin` przy logowaniu.
Można też ręcznie w Compass: kolekcja `users`, pole `role: "admin"` – zostaje przy kolejnych logowaniach.

---

## Konfiguracja do testów lokalnych (bez frontu)

### 0. Wspólne (`.env`)

```bash
# sekret do podpisywania tokenów, min. 32 znaki:
python -c "import secrets; print(secrets.token_urlsafe(48))"
```
```dotenv
JWT_SECRET=<wynik powyżej>
ADMIN_EMAILS=twoj.mail@gmail.com
AUTH_REDIRECT_URL=          # puste = callback zwraca JSON z tokenem
AUTH_DEV_LOGIN=true         # tylko lokalnie! patrz niżej
```

### 1. GitHub (ok. 2 min)

1. GitHub → **Settings → Developer settings → OAuth Apps → New OAuth App**
   (https://github.com/settings/applications/new)
2. Wypełnij:
   - *Application name*: `HackYeah dev`
   - *Homepage URL*: `http://localhost:8000`
   - *Authorization callback URL*: **`http://localhost:8000/auth/github/callback`**
3. **Register application** → skopiuj *Client ID*, potem **Generate a new client secret**.
4. Do `.env`:
   ```dotenv
   GITHUB_CLIENT_ID=...
   GITHUB_CLIENT_SECRET=...
   ```

### 2. Google (ok. 5 min)

1. https://console.cloud.google.com → wybierz / utwórz projekt.
2. **APIs & Services → OAuth consent screen** (Google Auth Platform → Branding/Audience):
   typ **External**, nazwa aplikacji, Twój e-mail. Dopóki aplikacja jest w trybie *Testing*,
   zalogować mogą się tylko **Test users** – dodaj tam swój adres (i adresy kolegów).
3. **APIs & Services → Credentials → Create credentials → OAuth client ID**
   - *Application type*: **Web application**
   - *Authorized redirect URIs*: **`http://localhost:8000/auth/google/callback`**
4. Skopiuj *Client ID* i *Client secret* do `.env`:
   ```dotenv
   GOOGLE_CLIENT_ID=...apps.googleusercontent.com
   GOOGLE_CLIENT_SECRET=...
   ```

Provider jest włączony, gdy ma ustawione oba pola – można mieć tylko jednego.

### 3. Test w przeglądarce

```bash
fastapi dev app/main.py
```

1. http://localhost:8000/auth/providers – powinny być widoczne `github` i/lub `google`.
2. Otwórz **http://localhost:8000/auth/github/login** (albo `/auth/google/login`), zaloguj się.
3. Po powrocie przeglądarka pokaże JSON – skopiuj `access_token`.
4. Użyj go:
   - Swagger http://localhost:8000/docs → **Authorize** → wklej token,
   - Postman: zmienna `token` w kolekcji (patrz [`postman/README.md`](../postman/README.md)),
   - curl: `-H "Authorization: Bearer <token>"`.
5. `GET /auth/me` pokazuje Twój profil i rolę.

> Używaj **`localhost`**, nie `127.0.0.1` – adres callbacku musi się zgadzać co do znaku
> z tym wpisanym u providera, a ciasteczko z `state` jest przypisane do hosta.

### 4. Bez OAuth: `dev-login`

Przy `AUTH_DEV_LOGIN=true`:
```bash
curl -X POST http://localhost:8000/auth/dev-login -H "Content-Type: application/json" -d @examples/requests/dev-login-user.json
curl -X POST http://localhost:8000/auth/dev-login -H "Content-Type: application/json" -d @examples/requests/dev-login-admin.json
```
Wydaje token dla dowolnej nazwy i roli – idealne do Postmana i testowania uprawnień
(user A vs user B vs admin). **Na produkcji musi być wyłączone** (domyślnie jest).

---

## Integracja z frontendem

1. Ustaw `AUTH_REDIRECT_URL` na stronę frontu, np. `http://localhost:3000/auth/callback`.
2. Przycisk „Zaloguj przez GitHub” = zwykły link do `http://<api>/auth/github/login`
   (listę dostępnych metod daje `GET /auth/providers`).
3. Po zalogowaniu backend przekieruje na
   `http://localhost:3000/auth/callback#access_token=...&expires_in=86400`.
   Front czyta token z `location.hash` (fragment nie trafia do serwerów ani logów),
   zapisuje go i czyści adres (`history.replaceState`).
4. Każde zapytanie zapisujące: `Authorization: Bearer <access_token>`. Odpowiedź `401` = token
   wygasł → ponowne logowanie.
5. Jeśli front będzie na innej domenie niż API, trzeba będzie dodać CORS (na razie nie ma).

## Produkcja – checklista

- `JWT_SECRET` długi i losowy, ten sam na wszystkich instancjach; zmiana unieważnia wszystkie tokeny.
- `AUTH_DEV_LOGIN=false`.
- HTTPS; u providerów callbacki z produkcyjną domeną (`https://api.twoja-domena/auth/github/callback`).
- Za reverse proxy uruchamiać uvicorn z `--proxy-headers`, żeby callback URL miał `https://`.
- Google: przełączyć consent screen z *Testing* na *In production*.
