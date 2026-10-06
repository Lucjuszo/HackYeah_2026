#!/usr/bin/env bash
# Builds the production images for the Raspberry Pi (linux/arm64) on this PC and, optionally, ships them.
#
#   deploy/build.sh --api-url https://api.example.com                      # build + dist/thirdplaces-images.tar.gz
#   deploy/build.sh --api-url https://api.example.com --deploy pi@raspberrypi.local
#       ...then copy the images and docker-compose.yml to the Pi (~/thirdplaces) and restart the stack
#
# Options:
#   --api-url URL     public backend address compiled into the Flutter app (or env API_URL) - required
#   --deploy HOST     ssh target (user@host); --dir sets the directory there (default: thirdplaces)
#   --tag TAG         image tag (default: latest)
#   --platform P      default linux/arm64 (64-bit Raspberry Pi OS); linux/arm/v7 for a 32-bit OS
#
# Needs Docker with buildx and arm64 emulation (Docker Desktop has both). On Windows: Git Bash or WSL.
# Flutter is built natively on this PC; the Pi only gets nginx + the finished files.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_DIR="$ROOT/deploy"
DIST="$ROOT/dist"

API_URL="${API_URL:-}"
PLATFORM="linux/arm64"
TAG="latest"
TARGET=""
REMOTE_DIR="thirdplaces"

die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --api-url) API_URL="${2:?}"; shift 2 ;;
    --deploy) TARGET="${2:?}"; shift 2 ;;
    --dir) REMOTE_DIR="${2:?}"; shift 2 ;;
    --tag) TAG="${2:?}"; shift 2 ;;
    --platform) PLATFORM="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

[ -n "$API_URL" ] || die "--api-url (or API_URL) is required, e.g. https://api.example.com"
case "$API_URL" in https://*|http://*) ;; *) die "API_URL must start with https:// or http://" ;; esac
docker buildx version >/dev/null 2>&1 || die "docker buildx not found"

BACKEND="thirdplaces-backend:$TAG"
FRONTEND="thirdplaces-frontend:$TAG"

echo "==> $BACKEND ($PLATFORM)"
docker buildx build \
  --platform "$PLATFORM" \
  --file "$DEPLOY_DIR/backend.Dockerfile" \
  --tag "$BACKEND" \
  --load \
  "$ROOT"

echo "==> $FRONTEND ($PLATFORM, API_URL=$API_URL)"
docker buildx build \
  --platform "$PLATFORM" \
  --file "$DEPLOY_DIR/frontend.Dockerfile" \
  --build-context deploy="$DEPLOY_DIR" \
  --build-arg API_URL="$API_URL" \
  --tag "$FRONTEND" \
  --load \
  "$ROOT/frontend"

mkdir -p "$DIST"
ARCHIVE="$DIST/thirdplaces-images.tar.gz"
echo "==> $ARCHIVE"
docker save "$BACKEND" "$FRONTEND" | gzip -1 > "$ARCHIVE"
COMPOSE_FILES=(docker-compose.yml backend-logging.json backend.env.example cloudflared.env.example)
for f in "${COMPOSE_FILES[@]}"; do cp "$DEPLOY_DIR/$f" "$DIST/"; done
echo "    $(du -h "$ARCHIVE" | cut -f1); on the Pi: gunzip -c thirdplaces-images.tar.gz | docker load"

if [ -z "$TARGET" ]; then
  echo "Done. Copy dist/ to the Pi, or run again with --deploy user@host."
  exit 0
fi

echo "==> $TARGET:$REMOTE_DIR"
ssh "$TARGET" "mkdir -p '$REMOTE_DIR'"
scp "${COMPOSE_FILES[@]/#/$DIST/}" "$TARGET:$REMOTE_DIR/"
# Stream the images straight into docker on the Pi (no copy of the archive on its SD card).
ssh "$TARGET" "docker load" < <(gunzip -c "$ARCHIVE")
# shellcheck disable=SC2016  # expanded on the Pi
ssh "$TARGET" "cd '$REMOTE_DIR' && for f in backend.env cloudflared.env; do
    [ -f \"\$f\" ] || { echo \"missing \$PWD/\$f: copy \$f.example and fill it in, then: docker compose up -d\" >&2; exit 1; }
  done
  TAG='$TAG' docker compose up -d --remove-orphans && docker image prune -f >/dev/null && docker compose ps"
