#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$ROOT_DIR/lib/ui.sh"
source "$ROOT_DIR/lib/util.sh"

use_defaults=false

strip_newlines() {
  printf '%s' "$1" | tr -d '\r\n'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --use-defaults)
      use_defaults=true
      shift
      ;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [--use-defaults]
Create or overwrite .env.deploy with interactive prompts.
EOF
      exit 0
      ;;
    *)
      log_warn "Ignoring unknown argument: $1"
      shift
      ;;
  esac
done

DEFAULT_FRONTEND="8080"
DEFAULT_BACKEND="3000"
DEFAULT_DB_PORT="5432"
DEFAULT_DB_USER="postgres"
DEFAULT_POSTGRES_DB="political_dashboard"
DEFAULT_FRONTEND_IMG="political-dashboard-frontend"
DEFAULT_BACKEND_IMG="political-dashboard-backend"

mask_value() {
  local name="$1"
  local value="$2"
  if printf '%s' "$name" | grep -qiE 'password|secret|token'; then
    local len=${#value}
    if [ "$len" -le 4 ]; then
      printf '****'
      return
    fi
    local visible="${value: -2}"
    local stars=$((len - 2))
    printf '%s%s' "$(printf '%*s' "$stars" '' | tr ' ' '*')" "$visible"
    return
  fi
  printf '%s' "$value"
}

if [ "$use_defaults" = true ]; then
  log_info "Using default environment values (ports 8080/3000/5432, user postgres)."
  FRONTEND_PORT="$(strip_newlines "$DEFAULT_FRONTEND")"
  BACKEND_PORT="$(strip_newlines "$DEFAULT_BACKEND")"
  DB_PORT="$(strip_newlines "$DEFAULT_DB_PORT")"
  POSTGRES_USER="$(strip_newlines "$DEFAULT_DB_USER")"
else
  FRONTEND_PORT="$(strip_newlines "$(read_value "Frontend port" "$DEFAULT_FRONTEND")")"
  BACKEND_PORT="$(strip_newlines "$(read_value "Backend port" "$DEFAULT_BACKEND")")"
  DB_PORT="$(strip_newlines "$(read_value "Database port" "$DEFAULT_DB_PORT")")"
  POSTGRES_USER="$(strip_newlines "$(read_value "Postgres user" "$DEFAULT_DB_USER")")"
fi

POSTGRES_PASSWORD=""
while [ -z "$POSTGRES_PASSWORD" ]; do
  POSTGRES_PASSWORD="$(strip_newlines "$(read_secret "Postgres password")")"
  if [ -z "$POSTGRES_PASSWORD" ]; then
    log_warn "Password cannot be empty. Please enter a value."
  fi
done

POSTGRES_DB="$(strip_newlines "$DEFAULT_POSTGRES_DB")"
DATABASE_URL="postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@db:5432/${POSTGRES_DB}"
FRONTEND_IMAGE="$(strip_newlines "$DEFAULT_FRONTEND_IMG")"
BACKEND_IMAGE="$(strip_newlines "$DEFAULT_BACKEND_IMG")"

log_info ""
log_info "Summary:"
for entry in \
  "FRONTEND_PORT=$FRONTEND_PORT" \
  "BACKEND_PORT=$BACKEND_PORT" \
  "DB_PORT=$DB_PORT" \
  "POSTGRES_USER=$POSTGRES_USER" \
  "POSTGRES_PASSWORD=$POSTGRES_PASSWORD" \
  "POSTGRES_DB=$POSTGRES_DB" \
  "DATABASE_URL=$DATABASE_URL" \
  "FRONTEND_IMAGE=$FRONTEND_IMAGE" \
  "BACKEND_IMAGE=$BACKEND_IMAGE"
do
  key="${entry%%=*}"
  val="${entry#*=}"
  printf '  %s = %s\n' "$key" "$(mask_value "$key" "$val")"
done

target_dir="$PWD"
if [ ! -w "$target_dir" ]; then
  target_dir="$ROOT_DIR"
fi
env_file="$target_dir/.env.deploy"

if [ -f "$env_file" ]; then
  if ! confirm_action ".env.deploy already exists at $env_file. Overwrite?"; then
    log_warn "Aborted. Existing file left untouched."
    exit 0
  fi
fi

cat >"$env_file" <<EOF
FRONTEND_PORT=$FRONTEND_PORT
BACKEND_PORT=$BACKEND_PORT
DB_PORT=$DB_PORT
POSTGRES_USER=$POSTGRES_USER
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=$POSTGRES_DB
DATABASE_URL=$DATABASE_URL
FRONTEND_IMAGE=$FRONTEND_IMAGE
BACKEND_IMAGE=$BACKEND_IMAGE
EOF

log_info ".env.deploy written to $env_file"
printf '%s\n' "$env_file"
