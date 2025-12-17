#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$ROOT_DIR/lib/ui.sh"
source "$ROOT_DIR/lib/util.sh"

get_default_local_root() {
  local deploy_root="$1"
  local candidate="$deploy_root"
  if [ ! -f "$candidate/docker-compose.yml" ]; then
    local parent
    parent="$(cd "$candidate/.." && pwd)"
    if [ -f "$parent/docker-compose.yml" ]; then
      candidate="$parent"
    fi
  fi
  printf '%s' "$candidate"
}

copy_with_exclude_node_modules() {
  local source_dir="$1"
  local destination="$2"
  require_cmd rsync
  mkdir -p "$destination"
  # rsync is used to mimic robocopy /MIR while skipping node_modules.
  rsync -a --delete --exclude 'node_modules' --quiet "$source_dir/" "$destination/"
}

invoke_sync_strategy() {
  local user="$1"
  local server="$2"
  local port="$3"
  local remote_dir="$4"
  local deploy_root="$5"
  local env_file="$6"

  require_cmd ssh
  require_cmd scp
  require_cmd rsync

  local default_root
  default_root="$(get_default_local_root "$deploy_root")"
  local local_root=""
  while [ -z "$local_root" ]; do
    local input_value
    input_value="$(read_value "Choose local project root" "$default_root")"
    if [ ! -d "$input_value" ]; then
      log_warn "Path not found: $input_value"
      continue
    fi
    local resolved
    resolved="$(cd "$input_value" && pwd)"
    if [ ! -f "$resolved/docker-compose.yml" ]; then
      log_warn "docker-compose.yml not found in $resolved"
      continue
    fi
    local_root="$resolved"
  done

  for item in backend frontend docker-compose.yml docker-compose.prod.yml; do
    if [ ! -e "$local_root/$item" ]; then
      new_error "Required item missing ($item) at $local_root/$item"
    fi
  done
  if [ ! -f "$env_file" ]; then
    new_error "Required item missing (.env.deploy) at $env_file"
  fi

  local ssh_target="${user}@${server}"
  local staging=""
  staging="$(mktemp -d)"
  trap 'tmp="${staging:-}"; [ -n "$tmp" ] && rm -rf "$tmp"' RETURN

  copy_with_exclude_node_modules "$local_root/backend" "$staging/backend"
  copy_with_exclude_node_modules "$local_root/frontend" "$staging/frontend"
  cp "$local_root/docker-compose.yml" "$staging/"
  cp "$local_root/docker-compose.prod.yml" "$staging/"
  cp "$env_file" "$staging/.env.deploy"

  local destination="$ssh_target:$remote_dir/"
  local scp_args=(
    -P "$port"
    -q
    -o StrictHostKeyChecking=accept-new
    -r
    "$staging/backend"
    "$staging/frontend"
    "$staging/docker-compose.yml"
    "$staging/docker-compose.prod.yml"
    "$staging/.env.deploy"
    "$destination"
  )

  if ! scp "${scp_args[@]}"; then
    new_error "scp exited with code $?"
  fi
  log_success "Copied project assets (excluding node_modules) to $destination"
}
