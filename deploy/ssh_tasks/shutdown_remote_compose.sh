#!/usr/bin/env bash
set -euo pipefail

: "${REMOTE_DIR:?REMOTE_DIR must be set}"

run_cmd() {
  if [ -n "${SUDO_CMD:-}" ]; then
    if [ -n "${SUDO_PASSWORD:-}" ]; then
      printf '%s\n' "$SUDO_PASSWORD" | $SUDO_CMD "$@"
    else
      $SUDO_CMD "$@"
    fi
  else
    "$@"
  fi
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

compose_file="$(choose_compose_file "$REMOTE_DIR")"
if [ -z "$compose_file" ]; then
  exit 0
fi

compose_cmd="$(detect_compose_cmd "$REMOTE_DIR")"
if [ -z "$compose_cmd" ]; then
  echo "Docker Compose is not available on the remote host" >&2
  exit 1
fi

# shellcheck disable=SC2206
compose_parts=($compose_cmd)
run_cmd "${compose_parts[@]}" -f "$compose_file" down
