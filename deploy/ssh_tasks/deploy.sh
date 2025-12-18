#!/usr/bin/env bash
set -euo pipefail

: "${REMOTE_DIR:?REMOTE_DIR must be set}"

LOG_DIR="/var/log/political-dashboard"
LOG_FILE="$LOG_DIR/deploy.log"

ENV_FILE="$REMOTE_DIR/.env.deploy"
DOCKER_COMPOSE_FILE="$REMOTE_DIR/docker-compose.prod.yml"

REMOTE_USER="$(id -un)"
REMOTE_GROUP="$(id -gn)"

SUDO_CMD=""

# TODO: FIX sorry, wrong password even if correct
# Sudo handling (same pattern as prepare_remote.sh)
if [ "$(id -u)" -eq 0 ]; then
    SUDO_CMD=""
elif command -v sudo >/dev/null 2>&1; then
    SUDO_CMD="sudo -S -p ''"
else
    echo "This script requires root or sudo to run docker commands" >&2
    exit 1
fi

if [ -n "$SUDO_CMD" ] && [ -z "${SUDO_PASSWORD:-}" ]; then
    echo "SUDO_PASSWORD is required for sudo operations" >&2
    exit 1
fi

log() {
  local ts msg host
  ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  host="$(hostname)"
  msg="[$ts] [$host] $*"
  printf '%s\n' "$msg"

  if [ -n "${LOG_FILE:-}" ] && [ -d "${LOG_DIR:-}" ]; then
    # If we have sudo configured, write log as root via sudo.
    # Otherwise (running as root) write directly.
    if [ -n "${SUDO_CMD:-}" ]; then
      # Use sh -c so sudo reads only the password from stdin,
      # and the log message is passed as an argument.
      run_cmd sh -c 'printf "%s\n" "$1" >> "$2"' _ "$msg" "$LOG_FILE" || true
    else
      # root: no sudo needed
      printf '%s\n' "$msg" >> "$LOG_FILE" 2>/dev/null || true
    fi
  fi
}

run_cmd() {
    if [ -z "$SUDO_CMD" ]; then
        "$@"
    else
        printf '%s\n' "$SUDO_PASSWORD" | $SUDO_CMD "$@"
    fi
}

ensure_log_dir() {
    run_cmd mkdir -p "$LOG_DIR"
    run_cmd chown "$REMOTE_USER:$REMOTE_GROUP" "$LOG_DIR"
}


detect_compose_cmd() {
if [ -f "$REMOTE_DIR/.compose_cmd" ]; then
  # shellcheck disable=SC1090
  source "$REMOTE_DIR/.compose_cmd"
fi
  if [ -n "${DOCKER_COMPOSE_CMD:-}" ]; then
    echo "$DOCKER_COMPOSE_CMD"
    return
  fi
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose"
    return
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"
    return
  fi
  log "Docker Compose not available" >&2
  exit 1
}

compose() {
  local action="$1"; shift
  local cmd_str
  cmd_str="$(detect_compose_cmd)"
  read -r -a compose_cmd <<< "$cmd_str"
  run_cmd "${compose_cmd[@]}" -f "$DOCKER_COMPOSE_FILE" --env-file "$ENV_FILE" "$action" "$@"
}

main() {
  ensure_log_dir
  log "starting deploy"

  if [ ! -f "$ENV_FILE" ]; then
    log "env file not found at $ENV_FILE" >&2
    exit 1
  fi
  if [ ! -f "$DOCKER_COMPOSE_FILE" ]; then
    log "compose file not found at $DOCKER_COMPOSE_FILE" >&2
    exit 1
  fi

  log "running docker compose down"
  compose down || true

  log "running docker compose build"
  if ! compose build; then
    log "Docker build failed" >&2
    exit 1
  fi

  log "running docker compose up -d"
  if ! compose up -d; then
    log "Docker up failed" >&2
    exit 1
  fi

  log "deploy finished successfully"
}

main "$@"
