#!/usr/bin/env bash
set -euo pipefail

# Validate sudo availability and password.
# Expects SUDO_PASSWORD to be set when not running as root.

if [ "$(id -u)" -eq 0 ]; then
  printf 'ok:root\n'
  exit 0
fi

if ! command -v sudo >/dev/null 2>&1; then
  printf 'error:missing_sudo\n'
  exit 0
fi

if [ -z "${SUDO_PASSWORD:-}" ]; then
  printf 'error:missing_password\n'
  exit 0
fi

output="$(printf '%s\n' "$SUDO_PASSWORD" | sudo -S -p '' -v 2>&1)" && {
  printf 'ok:authorized\n'
  exit 0
}

lower_output="$(printf '%s' "$output" | tr '[:upper:]' '[:lower:]')"

if printf '%s' "$lower_output" | grep -qE 'not in the sudoers|may not run sudo|not allowed|may not run sudo on'; then
  printf 'error:not_in_sudoers\n'
  exit 0
fi
if printf '%s' "$lower_output" | grep -q 'incorrect password' ; then
  printf 'error:bad_password\n'
  exit 0
fi

printf 'error:unknown\n'
