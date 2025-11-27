#!/usr/bin/env bash
set -euo pipefail

: "${REMOTE_DIR:?REMOTE_DIR must be set}"

log() {
    local msg="[prepare_remote] $*"
    printf '%s\n' "$msg"
    if [ -n "${LOG_FILE:-}" ] && [ -d "${LOG_DIR:-}" ]; then
        if [ -n "$SUDO" ]; then
        printf '%s\n' "$msg" | $SUDO tee -a "$LOG_FILE" >/dev/null || true
        else
        printf '%s\n' "$msg" >> "$LOG_FILE" 2>/dev/null || true
        fi
    fi
}

REMOTE_USER="$(id -un)"
REMOTE_GROUP="$(id -gn)"
LOG_DIR="/var/log/political-dashboard"
LOG_FILE="$LOG_DIR/prepare_remote.log"
SUDO=""
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
elif command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
else
    log "This script requires root or passwordless sudo to install dependencies and adjust ownership" >&2
    exit 1
fi

require_apt() {
    if ! command -v apt-get >/dev/null 2>&1; then
        log "apt-get is required on the remote host" >&2
        exit 1
    fi
}

APT_UPDATED=0
apt_update_once() {
    if [ "$APT_UPDATED" -eq 0 ]; then
        $SUDO apt-get update -y
        APT_UPDATED=1
    fi
}

apt_install() {
    require_apt
    apt_update_once
    $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

ensure_base_packages() {
    # git
    if command -v git >/dev/null 2>&1; then
        return
    fi
    log "Installing git"
    apt_install git
    
    # curl
    if command -v curl >/dev/null 2>&1; then
        return
    fi
    log "Installing curl"
    apt_install curl
}

ensure_directory() {
    local dir="$1"
    if ! mkdir -p "$dir" 2>/dev/null; then
        $SUDO mkdir -p "$dir"
    fi
}

ensure_owned_by_user() {
    local path="$1"
    ${SUDO:+$SUDO }chown -R "$REMOTE_USER:$REMOTE_GROUP" "$path"
}

ensure_log_dir() {
    ${SUDO:+$SUDO }mkdir -p "$LOG_DIR"
    ${SUDO:+$SUDO }chown "$REMOTE_USER:$REMOTE_GROUP" "$LOG_DIR"
}

ensure_docker() {
    if command -v docker >/dev/null 2>&1; then
        return
    fi
    log "Installing Docker engine"
    apt_install ca-certificates curl gnupg
    apt_install docker.io
    if command -v systemctl >/dev/null 2>&1; then
        $SUDO systemctl enable --now docker >/dev/null 2>&1 || true
    fi
}

ensure_compose() {
    if docker compose version >/dev/null 2>&1; then
        return
    fi
    if command -v docker-compose >/dev/null 2>&1; then
        return
    fi
    log "Installing Docker Compose plugin (fallback to legacy if unavailable)"
    if ! apt_install docker-compose-plugin; then
        apt_install docker-compose
    fi
}

detect_compose_cmd() {
    if docker compose version >/dev/null 2>&1; then
        echo "docker compose"
        return
    fi
    if command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
        return
    fi
    log "Docker Compose is not available after attempted installation" >&2
    exit 1
    }

main() {
    ensure_log_dir

    ensure_directory "$REMOTE_DIR"
    ensure_directory "$REMOTE_DIR/.state"
    ensure_owned_by_user "$REMOTE_DIR"

    ensure_base_packages
    ensure_docker
    ensure_compose

    compose_cmd="$(detect_compose_cmd)"
    printf "DOCKER_COMPOSE_CMD='%s'\n" "$compose_cmd" > "$REMOTE_DIR/.compose_cmd"
    ensure_owned_by_user "$REMOTE_DIR/.compose_cmd"
}

main "$@"
