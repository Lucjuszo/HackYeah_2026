# Produkcja na Raspberry Pi (Docker + tunel Cloudflare)

Raspberry Pi 3B+ (1 GB) z **64-bitowym** Raspberry Pi OS, Docker i plugin `docker compose`.
Baza to MongoDB Atlas. Na Pi działają trzy kontenery, a zdjęcia i logi leżą na osobnych wolumenach Dockera:

| Kontener | Co robi | Limit RAM |
|---|---|---|
| `backend` | FastAPI (uvicorn) | 512 MB |
| `frontend` | nginx z gotowym Flutter web | 64 MB |
| `cloudflared` | tunel Cloudflare; Pi nie wystawia żadnego portu | 128 MB |

| Wolumen | Zawartość |
|---|---|
| `thirdplaces_media` | zdjęcia (`STORAGE_BACKEND=local`), backend serwuje je pod `https://api.<domena>/media/...` |
| `thirdplaces_logs` | `backend/backend.log` (rotacja 4 × 2 MB), `nginx/error.log`, `cloudflared/cloudflared.log` |

Logi zawierają tylko ostrzeżenia i błędy, bez linii na każde zapytanie. Kopia w `docker compose logs`
jest mała (2 × 2 MB na kontener). Kontener `log-dirs` przy starcie zakłada katalogi logów
z uprawnieniami dla użytkowników, jako których działają usługi.

## 1. Tunel (raz)

Cloudflare Zero Trust → Networks → Tunnels → *Create a tunnel* (cloudflared). Skopiuj token, a w
*Public hostnames* dodaj:

- `<domena>` (bez subdomeny) → `http://frontend:80`
- `api.<domena>` → `http://backend:8000`

## 2. Obrazy (GitHub Actions)

Na Pi nic się nie buduje. `.github/workflows/deploy.yml` uruchamia się po zielonym workflow *Tests*
dla pusha na `main` (albo ręcznie: Actions → *Deploy images* → *Run workflow* na `main`) i wypycha:

- `ghcr.io/lucjuszo/thirdplaces-backend` — budowany natywnie na runnerze arm64;
- `ghcr.io/lucjuszo/thirdplaces-frontend` — Flutter budowany na amd64, na arm64 tylko nginx z plikami.

Każdy obraz ma tagi `latest` i `sha-<7 znaków commita>`. `API_URL` frontu to zmienna repozytorium
`API_URL` (Settings → Secrets and variables → Actions → Variables), domyślnie `https://api.thirdplaces.pl`;
jest wkompilowany we front, więc po zmianie trzeba puścić workflow ponownie.

Pakiety w GHCR są prywatne (domyślne ustawienie) i dziedziczą dostęp z repo, więc Pi loguje się do GHCR
tokenem współpracownika repo (krok w punkcie 3). Ustawienia po stronie właściciela repo: [GHCR-SETUP.md](GHCR-SETUP.md).

## 3. Pi (raz)

Na Pi nic się nie buduje. `~/thirdplaces` to klon repo z samym katalogiem `deploy/` (sparse checkout).
Timer systemd co 5 minut uruchamia `deploy/update.sh`, który:

1. robi `git fetch` + `git reset --hard origin/main` (nowy `docker-compose.yml`, `backend-logging.json`, sam skrypt);
2. pobiera `backend` i `frontend` z GHCR;
3. tylko jeśli coś się zmieniło: `docker compose up -d` (podmienia tylko zmienione kontenery) i usuwa stare obrazy.

`backend.env`, `cloudflared.env` i `.env` są w `.gitignore`, więc reset ich nie rusza.

Atlas → Network Access: dodaj publiczny adres IP Pi. W GitHub/Google ustaw callbacki
`https://api.<domena>/auth/github/callback` i `https://api.<domena>/auth/google/callback`.
Użytkownik musi być w grupie `docker` (`sudo usermod -aG docker $USER`, potem ponowne logowanie).

Logowanie do GHCR: GitHub → Settings → Developer settings → Personal access tokens → **Tokens (classic)**
→ *Generate new token (classic)* z samym uprawnieniem `read:packages` (fine-grained tokeny nie działają z GHCR).
Data ważności tokenu = data, po której Pi przestanie się aktualizować; wtedy nowy token i ponowny `docker login`.

```bash
sudo apt-get install -y git
docker login ghcr.io -u <login-github>   # hasło = token read:packages; zapis w ~/.docker/config.json
git clone --filter=blob:none --no-checkout https://github.com/Lucjuszo/HackYeah_2026.git ~/thirdplaces
cd ~/thirdplaces && git sparse-checkout set --no-cone /deploy/ && git checkout main
cd deploy
cp backend.env.example backend.env && nano backend.env              # Atlas, adresy, JWT, OAuth
cp cloudflared.env.example cloudflared.env && nano cloudflared.env  # TUNNEL_TOKEN
docker compose pull && docker compose up -d

sudo cp systemd/thirdplaces-update@.service systemd/thirdplaces-update@.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now thirdplaces-update@$USER.timer
```

Od tej pory każdy merge na `main` trafia na Pi sam: do ~5 min po zakończeniu workflow *Deploy images*.
Zmiany w plikach `systemd/` trzeba skopiować do `/etc/systemd/system/` ręcznie (jak wyżej).

Przypięcie wersji: `echo TAG=sha-abc1234 > ~/thirdplaces/deploy/.env && docker compose up -d`.
Powrót na bieżącą: `rm ~/thirdplaces/deploy/.env && docker compose up -d`.

## Na Pi

```bash
cd ~/thirdplaces/deploy
systemctl list-timers 'thirdplaces*'                # kiedy następne sprawdzenie
journalctl -u 'thirdplaces-update@*' -n 50         # co i kiedy zostało zaktualizowane
sudo systemctl start thirdplaces-update@$USER      # aktualizacja od razu, bez czekania
docker compose ps                # stan i healthcheck
docker compose logs -f backend   # ostrzeżenia i błędy
docker compose restart backend   # po zmianie backend.env
docker compose exec backend tail -f /logs/backend/backend.log
docker run --rm -v thirdplaces_media:/media -v "$PWD":/backup busybox tar czf /backup/media.tgz -C /media .   # kopia zdjęć
```
