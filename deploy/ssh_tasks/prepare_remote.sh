#!/usr/bin/env bash
set -euo pipefail

: "${REMOTE_DIR:?REMOTE_DIR must be set}"

log() {
  local ts msg
  ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  host="$(hostname)" 
  msg="[$ts] [$host] $*"
  printf '%s\n' "$msg"
}
REMOTE_USER="$(id -un)"
REMOTE_GROUP="$(id -gn)"

SUDO_CMD=""

# TODO: FIX sorry, wrong password even if correct
# Sudo handling:
# - If running as root -> no sudo needed
# - If not root -> always use sudo -S -p '' and REQUIRE SUDO_PASSWORD
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

require_apt() {
    if ! command -v apt-get >/dev/null 2>&1; then
        log "apt-get is required on the remote host" >&2
        exit 1
    fi
}

APT_UPDATED=0
apt_update_once() {
    if [ "$APT_UPDATED" -eq 0 ]; then
        run_cmd apt-get update -y
        APT_UPDATED=1
    fi
}

apt_install() {
    require_apt
    apt_update_once
    # Use env so DEBIAN_FRONTEND is preserved through sudo
    run_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

ensure_pkg() {
  local pkg="$1"
  local check_bin="${2:-$1}"
  if command -v "$check_bin" >/dev/null 2>&1; then
    return
  fi
  log "Installing ${pkg}"
  apt_install "$pkg"
}

ensure_base_packages() {
  ensure_pkg git git
  ensure_pkg curl curl
}

ensure_directory() {
    local dir="$1"
    if ! mkdir -p "$dir" 2>/dev/null; then
        run_cmd mkdir -p "$dir"
    fi
}

ensure_owned_by_user() {
    local path="$1"
    run_cmd chown -R "$REMOTE_USER:$REMOTE_GROUP" "$path"
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker engine"
    apt_install ca-certificates curl gnupg
    apt_install docker.io
  fi

  # Start/enable if systemd is available
  if command -v systemctl >/dev/null 2>&1; then
    # If docker service exists, enable+start it
    if systemctl list-unit-files | grep 'docker'; then
      log "Ensuring Docker service is enabled and running"
      run_cmd systemctl enable --now docker >/dev/null 2>&1 || true
    fi
  fi
}

install_compose_binary() {
  local version="${COMPOSE_VERSION:-v2.29.7}"
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    armv7l) arch="armv7" ;;
    *) log "Unsupported architecture for Docker Compose: ${arch}" >&2; return 1 ;;
  esac

  local url="https://github.com/docker/compose/releases/download/${version}/docker-compose-Linux-${arch}"
  local dest="/usr/lib/docker/cli-plugins/docker-compose"

  log "Downloading Docker Compose plugin binary ${version} for ${arch}"
  run_cmd mkdir -p /usr/lib/docker/cli-plugins
  run_cmd curl -fL "$url" -o "$dest"
  run_cmd chmod +x "$dest"
}

ensure_compose() {
  if docker compose version >/dev/null 2>&1; then
    return
  fi

  log "Installing Docker Compose plugin"
  if ! apt_install docker-compose-plugin; then
    log "docker-compose-plugin package not found; attempting manual install" >&2
    install_compose_binary
  fi

  if ! docker compose version >/dev/null 2>&1; then
    log "Docker Compose plugin installation failed" >&2
    exit 1
  fi
}

detect_compose_cmd() {
  if ! docker compose version >/dev/null 2>&1; then
    log "Docker Compose plugin is not available after attempted installation" >&2
    exit 1
  fi

  echo "docker compose"
}

main() {
    sudo_validate
    log "starting preparation"

    log "ensuring ${REMOTE_DIR} exists"
    ensure_directory "$REMOTE_DIR"

    log "ensuring ${REMOTE_DIR} is owned by ${REMOTE_USER}"
    ensure_owned_by_user "$REMOTE_DIR"

    log "ensuring base packages are installed"
    ensure_base_packages
    log "ensuring docker is installed"
    ensure_docker
    log "ensuring compose is installed"
    ensure_compose

    compose_cmd="$(detect_compose_cmd)"
    run_cmd sh -c 'printf "DOCKER_COMPOSE_CMD=\"%s\"\n" "$1" > "$2"' _ "$compose_cmd" "$REMOTE_DIR/.compose_cmd"
    ensure_owned_by_user "$REMOTE_DIR/.compose_cmd"

    log "ended preparation"
}

main "$@"
