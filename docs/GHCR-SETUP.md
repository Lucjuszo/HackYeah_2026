# Ustawienia GitHuba dla deployu na Raspberry Pi (dla właściciela repo)

Obrazy produkcyjne budują się w GitHub Actions (`.github/workflows/deploy.yml`) i trafiają do
GitHub Container Registry (GHCR) na koncie właściciela repo:

- `ghcr.io/lucjuszo/thirdplaces-backend`
- `ghcr.io/lucjuszo/thirdplaces-frontend`

Pakiety zostają **prywatne** (domyślne ustawienie GHCR) i dziedziczą dostęp z repo. Raspberry Pi loguje się
do GHCR tokenem współpracownika, a co 5 minut pobiera wersję `latest` ([DEPLOY.md](DEPLOY.md)).

**W zwykłym przypadku właściciel repo nie musi nic robić.** Poniższe punkty są do sprawdzenia, gdyby coś nie działało.

## 1. Actions mogą działać

Repo → **Settings → Actions → General**:

- *Actions permissions*: zezwolone akcje GitHuba i zewnętrzne (używamy `actions/*` i `docker/*`),
  np. **Allow all actions and reusable workflows**.
- *Workflow permissions*: może zostać **Read repository contents**, bo workflow sam prosi o `packages: write`.

## 2. Workflow się uruchamia

Workflow **Deploy images** startuje sam po każdym pushu na `main`, kiedy workflow **Tests** przejdzie na zielono.
Ręcznie: **Actions → Deploy images → Run workflow → Branch: main → Run workflow**.

## 3. Ustawienia pakietów (po pierwszym przebiegu)

GitHub → **Your profile → Packages** → pakiet → **Package settings**. Dla obu pakietów:

- **Inherit access from source repository** ma być włączone. Wtedy współpracownicy repo mogą pobierać obrazy, w tym Pi.
  Gdyby tej opcji nie było, a `docker pull` na Pi kończył się `unauthorized`: **Manage access → Invite** i dodaj
  konto współpracownika z rolą **Read**.
- **Manage Actions access**: repo `HackYeah_2026` z rolą **Write**. GitHub dodaje to sam przy pierwszym pushu;
  bez tego kolejne buildy nie wypchną obrazów.
- Widoczności nie trzeba zmieniać. Upublicznienie (*Danger Zone → Change visibility → Public*) też zadziała,
  wtedy Pi nie potrzebowałoby nawet logowania, ale nie jest wymagane.

## 4. Opcjonalnie: adres API

Front ma wkompilowany adres backendu, domyślnie `https://api.thirdplaces.pl`. Jeśli się zmieni:
repo → **Settings → Secrets and variables → Actions → Variables → New repository variable**,
nazwa `API_URL`, wartość np. `https://api.nowa-domena.pl`. Potem ręcznie **Deploy images** (punkt 2).

## Na co dzień

Merge na `main` → testy → build obrazów → Pi pobiera je w ciągu ~5 minut.
Stare wersje pakietów można co jakiś czas usuwać w **Package settings → Manage versions**,
ale nie tę z tagiem `latest`.
