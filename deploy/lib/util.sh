#!/usr/bin/env bash
# Generic helpers that don't depend on the deployment flow.

if ! command -v log_error >/dev/null 2>&1; then
  log_error() {
    printf '%s\n' "$*" >&2
  }
fi

new_error() {
  local message="${1:-unknown error}"
  log_error "error: $message"
  exit 1
}

require_cmd() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    new_error "missing required command: $name"
  fi
}

escape_squotes() {
  printf "%s" "$1" | sed "s/'/'\"'\"'/g"
}

read_env_value() {
  local path="$1"
  local key="$2"
  [ -f "$path" ] || return 1
  awk -F= -v k="$key" '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    $1 == k { sub(/^[^=]*=/, "", $0); print; exit }
  ' "$path"
}

ensure_local_ssh_key() {
  local key_dir="$HOME/.ssh"
  local key_path="$key_dir/id_ed25519"
  local pub_path="$key_path.pub"

  mkdir -p "$key_dir"
  if [ ! -f "$key_path" ] || [ ! -f "$pub_path" ]; then
    if command -v log_info >/dev/null 2>&1; then
      log_info "Generating SSH key at $key_path" >&2
    else
      printf '%s\n' "Generating SSH key at $key_path" >&2
    fi
    if ! ssh-keygen -t ed25519 -N '' -f "$key_path" >/dev/null; then
      new_error "failed to generate SSH key at $key_path"
    fi
  fi
  if [ ! -f "$pub_path" ]; then
    new_error "SSH public key missing at $pub_path (generation failed?)"
  fi
  printf '%s' "$pub_path"
}
