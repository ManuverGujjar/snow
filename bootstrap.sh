#!/usr/bin/env bash
#
# bootstrap.sh — idempotent setup for the snow triage stack.
#
#   * installs Docker (+ compose plugin) if missing
#   * creates .env from .env.example with strong, STABLE secrets on first run
#   * brings the stack up
#   * pulls the Ollama model named in .env
#
# Safe to run repeatedly: secrets are generated only once, the model pull and
# `compose up` are both no-ops when already done.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }

# In-place sed that works on both GNU (Linux) and BSD/macOS.
sedi() { if sed --version >/dev/null 2>&1; then sed -i "$@"; else sed -i '' "$@"; fi; }

# Runtime keys that are safe to change anytime and should track .env.example.
# Everything else in .env is preserved: generated secrets AND your own
# deployment overrides (URLs, tokens, DB name, timezone).
MANAGED_KEYS="OLLAMA_MODEL OLLAMA_KEEP_ALIVE"

# Keep an existing .env in step with the template without clobbering anything
# you care about: append keys the template gained, re-sync only MANAGED_KEYS.
reconcile_env() {
  # 1. Append keys present in .env.example but missing from .env.
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    [ "${line#*=}" = "$line" ] && continue   # not a KEY=VALUE line
    key="${line%%=*}"
    if ! grep -q "^${key}=" .env; then
      printf '%s\n' "$line" >> .env
      log "added new config key from template: ${key}"
    fi
  done < .env.example

  # 2. Re-sync managed runtime keys from the template.
  for key in $MANAGED_KEYS; do
    want="$(grep "^${key}=" .env.example | head -n1 || true)"
    have="$(grep "^${key}=" .env | head -n1 || true)"
    if [ -n "$want" ] && [ -n "$have" ] && [ "$have" != "$want" ]; then
      sedi "s|^${key}=.*|${want}|" .env
      log "synced ${key} from template: ${have#*=} -> ${want#*=}"
    fi
  done
}

# ---------------------------------------------------------------------------
# 1. Docker
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  log "Docker not found — installing via get.docker.com (needs sudo)…"
  curl -fsSL https://get.docker.com | sudo sh
  sudo usermod -aG docker "$USER" || true
  warn "Added $USER to the 'docker' group. Log out/in (or run 'newgrp docker') if docker needs sudo."
else
  log "Docker present: $(docker --version)"
fi

# Compose plugin check (v2). `docker compose`, not the legacy `docker-compose`.
if ! docker compose version >/dev/null 2>&1; then
  warn "The Docker Compose v2 plugin is missing. Install it, then re-run this script."
  exit 1
fi

# Helper that works whether or not the user is in the docker group yet.
DOCKER="docker"
if ! docker info >/dev/null 2>&1; then
  warn "Cannot talk to the Docker daemon as this user; falling back to sudo."
  DOCKER="sudo docker"
fi

# ---------------------------------------------------------------------------
# 2. .env with strong, stable secrets
# ---------------------------------------------------------------------------
gen() { openssl rand -hex "$1"; }

if [ ! -f .env ]; then
  log "Creating .env from .env.example with freshly generated secrets…"
  cp .env.example .env

  POSTGRES_PASSWORD="$(gen 24)"
  N8N_ENCRYPTION_KEY="$(gen 24)"   # stable for the life of this .env
  NTFY_TOPIC="snow-$(gen 10)"      # unguessable; this is your access control

  sedi "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${POSTGRES_PASSWORD}|" .env
  sedi "s|^N8N_ENCRYPTION_KEY=.*|N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}|" .env
  sedi "s|^NTFY_TOPIC=.*|NTFY_TOPIC=${NTFY_TOPIC}|" .env

  log ".env created. Your ntfy topic is: ${NTFY_TOPIC}"
  warn "Subscribe to that exact topic on your phone (see README)."
else
  log ".env already exists — leaving its secrets (and N8N_ENCRYPTION_KEY) untouched."
fi

# Bring an existing .env up to date with non-secret template changes.
reconcile_env

# Load values we need below.
set -a; . ./.env; set +a
: "${OLLAMA_MODEL:?OLLAMA_MODEL must be set in .env}"

# ---------------------------------------------------------------------------
# 3. Bring the stack up
# ---------------------------------------------------------------------------
log "Starting the stack…"
$DOCKER compose up -d

# ---------------------------------------------------------------------------
# 4. Pull the Ollama model (idempotent — Ollama skips layers it already has)
# ---------------------------------------------------------------------------
log "Waiting for Ollama to be ready…"
for _ in $(seq 1 30); do
  if $DOCKER compose exec -T ollama ollama list >/dev/null 2>&1; then break; fi
  sleep 2
done

log "Pulling Ollama model: ${OLLAMA_MODEL} (first run downloads a few GB)…"
$DOCKER compose exec -T ollama ollama pull "${OLLAMA_MODEL}"

log "Done."
echo
echo "  n8n editor : http://127.0.0.1:5678   (first visit: create your owner account)"
echo "  ntfy       : http://127.0.0.1:8080"
echo
echo "Next: import the workflows in ./workflows and configure credentials — see README.md"
