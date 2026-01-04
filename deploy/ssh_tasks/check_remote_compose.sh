#!/usr/bin/env bash
set -euo pipefail

: "${REMOTE_DIR:?REMOTE_DIR must be set}"

# Sudo handling: root skips sudo; otherwise requires SUDO_PASSWORD.
if [ "$(id -u)" -eq 0 ]; then
  SUDO_CMD=()
elif command -v sudo >/dev/null 2>&1; then
  SUDO_CMD=(sudo -S -p "")
else
  echo "error:missing_sudo"
  exit 1
fi

if [ "${#SUDO_CMD[@]}" -gt 0 ] && [ -z "${SUDO_PASSWORD:-}" ]; then
  echo "error:missing_password"
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

if run_cmd test -f "$REMOTE_DIR/docker-compose.yml" || run_cmd test -f "$REMOTE_DIR/docker-compose.prod.yml"; then
  echo "present"
else
  echo "absent"
fi
