#!/usr/bin/env bash
# Runs on the Pi every 5 minutes (systemd/thirdplaces-update@.timer): follows main and updates the stack.
#   1. git: the sparse checkout of deploy/ (~/thirdplaces) is reset to origin/main
#      -> new docker-compose.yml / backend-logging.json / this script
#   2. docker: pulls backend/frontend from GHCR (built by .github/workflows/deploy.yml, never here)
#   3. only if 1 or 2 changed something: docker compose up -d + removal of the old images
# backend.env, cloudflared.env and .env (TAG=sha-... to pin a version) are git-ignored and stay untouched.
set -euo pipefail

# Wrapped in a function: bash reads it whole before running, so the git reset below can replace this file safely.
main() {
  cd "$(dirname "$(readlink -f "$0")")"

  local old_head new_head old_images new_images
  old_head=$(git rev-parse HEAD)
  git fetch --quiet origin main
  new_head=$(git rev-parse FETCH_HEAD)
  if [ "$old_head" != "$new_head" ]; then
    git reset --quiet --hard "$new_head"
    echo "repo: ${old_head:0:7} -> ${new_head:0:7}"
  fi

  old_images=$(image_ids)
  # Only our images: busybox and cloudflared are pinned, and polling Docker Hub would eat its rate limit.
  docker compose pull --quiet backend frontend
  new_images=$(image_ids)

  if [ "$old_head" = "$new_head" ] && [ "$old_images" = "$new_images" ]; then
    exit 0
  fi
  echo "updating the stack"
  docker compose up -d --remove-orphans --quiet-pull
  docker image prune -f >/dev/null
  docker compose ps --format 'table {{.Service}}\t{{.Image}}\t{{.Status}}'
}

image_ids() {
  docker compose config --images | sort -u | xargs -r docker image inspect -f '{{.Id}}' 2>/dev/null || true
}

main "$@"
