# Produkcja na Raspberry Pi (Docker + tunel Cloudflare)

Raspberry Pi 4B (4 GB) z **64-bitowym** Raspberry Pi OS, Docker i plugin `docker compose`.
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

## 2. Pi (raz)

Atlas → Network Access: dodaj publiczny adres IP Pi. W GitHub/Google ustaw callbacki
`https://api.<domena>/auth/github/callback` i `https://api.<domena>/auth/google/callback`.

W katalogu `~/thirdplaces` na Pi utwórz pliki (wzory trafiają tam przy pierwszym `--deploy`, są też w `deploy/`):

- `backend.env` z `backend.env.example`: Atlas, adresy, JWT, OAuth;
- `cloudflared.env` z `cloudflared.env.example`: `TUNNEL_TOKEN`.

## 3. Budowanie na PC i wgranie na Pi

Obrazy budują się na PC pod `linux/arm64`. Flutter buduje się natywnie na PC, więc na Pi trafia
tylko nginx z gotowymi plikami i backend. W Git Bash / WSL (Docker Desktop):

```bash
deploy/build.sh --api-url https://api.<domena> --deploy pi@raspberrypi.local
```

Skrypt buduje obrazy, przesyła je przez ssh (`docker load`), kopiuje `docker-compose.yml`
i `backend-logging.json`, a potem robi `docker compose up -d`. Bez `--deploy` zostawia `dist/thirdplaces-images.tar.gz` i pliki compose do
ręcznego przeniesienia (`gunzip -c thirdplaces-images.tar.gz | docker load`, potem `docker compose up -d`).

`API_URL` jest wkompilowany we front: przy zmianie adresu API trzeba go zbudować ponownie.

## Na Pi

```bash
cd ~/thirdplaces
docker compose ps                # stan i healthcheck
docker compose logs -f backend   # ostrzeżenia i błędy
docker compose restart backend   # po zmianie backend.env
docker compose exec backend tail -f /logs/backend/backend.log
docker run --rm -v thirdplaces_media:/media -v "$PWD":/backup busybox tar czf /backup/media.tgz -C /media .   # kopia zdjęć
```
