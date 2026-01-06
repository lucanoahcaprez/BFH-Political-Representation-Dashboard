#!/usr/bin/env bash
set -euo pipefail

: "${REMOTE_DIR:?REMOTE_DIR must be set}"

# Sudo handling:
# - If running as root -> no sudo needed
# - If not root -> sudo via stdin (no prompt text)
if [ "$(id -u)" -eq 0 ]; then
  SUDO_CMD=()
elif command -v sudo >/dev/null 2>&1; then
  SUDO_CMD=(sudo -S -p "")
else
  log "This script requires root or sudo to install dependencies and adjust ownership" >&2
  exit 1
fi

if [ "${#SUDO_CMD[@]}" -gt 0 ] && [ -z "${SUDO_PASSWORD:-}" ]; then
  log "SUDO_PASSWORD is required for sudo operations" >&2
  exit 1
fi

if [ -n "${SUDO_PASSWORD:-}" ]; then
  SUDO_PASSWORD="${SUDO_PASSWORD%$'\r'}"
fi

run_cmd() {
  if [ "${#SUDO_CMD[@]}" -eq 0 ]; then
    "$@"
  else
    printf '%s\n' "$SUDO_PASSWORD" | "${SUDO_CMD[@]}" -- "$@"
  fi
}

sudo_validate() {
  if [ "${#SUDO_CMD[@]}" -eq 0 ]; then
    return
  fi
  printf '%s\n' "$SUDO_PASSWORD" | "${SUDO_CMD[@]}" -v
}

choose_compose_file() {
  local dir="$1"
  if [ -f "$dir/docker-compose.prod.yml" ]; then
    echo "$dir/docker-compose.prod.yml"
  elif [ -f "$dir/docker-compose.yml" ]; then
    echo "$dir/docker-compose.yml"
  else
    echo ""
  fi
}

detect_compose_cmd() {
  local dir="$1"
  local cmd=""

  if [ -f "$dir/.compose_cmd" ]; then
    # shellcheck disable=SC1090
    . "$dir/.compose_cmd"
    cmd="${DOCKER_COMPOSE_CMD:-}"
  fi

  if [ -z "$cmd" ]; then
    if docker compose version >/dev/null 2>&1; then
      cmd="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
      cmd="docker-compose"
    fi
  fi

  if [ -z "$cmd" ]; then
    echo ""
  else
    echo "$cmd"
  fi
}

sudo_validate

compose_file="$(choose_compose_file "$REMOTE_DIR")"
if [ -z "$compose_file" ]; then
  exit 0
fi

compose_cmd="$(detect_compose_cmd "$REMOTE_DIR")"
if [ -z "$compose_cmd" ]; then
  echo "Docker Compose is not available on the remote host" >&2
  exit 1
fi

compose_parts=($compose_cmd)
run_cmd "${compose_parts[@]}" -f "$compose_file" down -v
