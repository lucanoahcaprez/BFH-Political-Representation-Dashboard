#!/usr/bin/env bash
# Lightweight UI helpers for logging and prompting.

UI_LOG_FILE=""
SHOW_INFO=true

set_ui_log_file() {
  UI_LOG_FILE="$1"
}

set_ui_info_visibility() {
  local visible="${1:-true}"
  SHOW_INFO=$([ "$visible" = "true" ] && echo true || echo false)
}

section() {
  local title="$1"
  local line="----------------------------------------------------------------"
  printf '\n%s\n> %s\n%s\n' "$line" "$title" "$line"
}

__ui_color() {
  local color="$1"
  case "$color" in
    red) printf '\033[31m' ;;
    green) printf '\033[32m' ;;
    yellow) printf '\033[33m' ;;
    cyan) printf '\033[36m' ;;
    reset) printf '\033[0m' ;;
    *) ;;
  esac
}

log_line() {
  local level="$1"
  shift
  local message="$*"
  local color="${LOG_COLOR:-}"
  local force_console="${FORCE_CONSOLE:-false}"

  local ts host line sanitized safe_message
  ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  host="$(hostname 2>/dev/null || echo 'local')"
  safe_message="$(printf '%s' "$message" | sed -E "s/SUDO_PASSWORD='[^']*'/SUDO_PASSWORD='***'/g; s/SUDO_PASSWORD=[^ ]*/SUDO_PASSWORD=***/g")"
  line="[$ts] [$host] [$level] $safe_message"
  sanitized="$(printf '%s' "$line")"

  if [ -n "$UI_LOG_FILE" ]; then
    printf '%s\n' "$sanitized" >>"$UI_LOG_FILE" || true
  fi

  if [ "$force_console" = "true" ] || [ "$SHOW_INFO" = "true" ] || [ "$level" != "INFO" ]; then
    local console_prefix=""
    case "$level" in
      INFO) console_prefix="." ;;
      SUCCESS) console_prefix="[OK]" ;;
      WARN) console_prefix="[WARN]" ;;
      ERROR) console_prefix="[ERR]" ;;
      *) console_prefix="$level" ;;
    esac
    local console_line="$console_prefix $safe_message"
    if [ -t 1 ] && [ -n "$color" ]; then
      __ui_color "$color"
      printf '%s\n' "$console_line"
      __ui_color "reset"
    else
      printf '%s\n' "$console_line"
    fi
  fi
}

log_info() {
  LOG_COLOR=""
  FORCE_CONSOLE=false
  log_line "INFO" "$@"
}

log_success() {
  LOG_COLOR="green"
  FORCE_CONSOLE=true
  log_line "SUCCESS" "$@"
}

log_warn() {
  LOG_COLOR="yellow"
  FORCE_CONSOLE=true
  log_line "WARN" "$@"
}

log_error() {
  LOG_COLOR="red"
  FORCE_CONSOLE=true
  log_line "ERROR" "$@"
}

read_prompt() {
  local message="$1"
  if [ -t 0 ]; then
    # Print to tty/stderr so the user always sees it, even if stdout is redirected.
    printf '%s: ' "$message" >/dev/tty 2>/dev/null || printf '%s: ' "$message" >&2
  else
    printf '%s: ' "$message" >&2
  fi
}

read_value() {
  local message="$1"
  local default="${2:-}"
  local prompt="$message"
  if [ -n "$default" ]; then
    prompt="$message [$default]"
  fi
  read_prompt "$prompt"
  IFS= read -r input_value || true
  if [ -z "$input_value" ] && [ -n "$default" ]; then
    printf '%s' "$default"
  else
    printf '%s' "$input_value"
  fi
}

confirm_action() {
  local message="${1:-Proceed?}"
  read_prompt "$message [y/N]"
  IFS= read -r response || true
  if printf '%s' "$response" | grep -qiE '^y(es)?$'; then
    return 0
  fi
  return 1
}

read_choice() {
  local message="$1"
  shift
  local options=("$@")
  if [ "${#options[@]}" -eq 0 ]; then
    log_error "read_choice requires at least one option"
    return 1
  fi
  local display
  display="$(printf '%s|' "${options[@]}")"
  display="${display%|}"
  while true; do
    read_prompt "$message"
    IFS= read -r input_value || true
    input_value="$(printf '%s' "$input_value" | sed 's/^ *//;s/ *$//')"
    for opt in "${options[@]}"; do
      if [ "$input_value" = "$opt" ]; then
        printf '%s' "$opt"
        return 0
      fi
      if [ "$(printf '%s' "$input_value" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$opt" | tr '[:upper:]' '[:lower:]')" ]; then
        printf '%s' "$opt"
        return 0
      fi
    done
    log_warn "Invalid choice. Allowed: $display"
  done
}

read_secret() {
  local message="$1"
  local old_stty
  old_stty="$(stty -g 2>/dev/null || true)"
  read_prompt "$message"
  stty -echo 2>/dev/null || true
  IFS= read -r secret || true
  stty "$old_stty" 2>/dev/null || true
  printf '\n'
  printf '%s' "$secret"
}
