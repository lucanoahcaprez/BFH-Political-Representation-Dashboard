#!/usr/bin/env bash
# SSH helpers that wrap ssh/scp with basic error handling.

source "$(dirname "${BASH_SOURCE[0]}")/ui.sh"
source "$(dirname "${BASH_SOURCE[0]}")/util.sh"

require_cmd ssh

normalize_newlines() {
  local src="$1"
  local dest="$2"
  # Ensure Unix newlines for remote execution.
  perl -pe 's/\r\n/\n/g' "$src" >"$dest"
}

test_ssh_connection() {
  local user="$1"
  local server="$2"
  local port="${3:-22}"
  local timeout="${4:-20}"
  local auth_mode="${5:-publickey,password}"

  local args=(
    -p "$port"
    -o "PreferredAuthentications=$auth_mode"
    -o StrictHostKeyChecking=accept-new
    -o BatchMode=yes
    -o "ConnectTimeout=$timeout"
    "$user@$server"
    "exit 0"
  )

  if ssh "${args[@]}" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

invoke_ssh_script() {
  local user="$1"
  local server="$2"
  local port="${3:-22}"
  local timeout="${4:-20}"
  local script="$5"

  local args=(
    -p "$port"
    -o PreferredAuthentications=publickey,password
    -o "ConnectTimeout=$timeout"
    -o StrictHostKeyChecking=accept-new
    "$user@$server"
    "set -euo pipefail; $script"
  )

  if ! ssh "${args[@]}"; then
    new_error "ssh exited with code $?"
  fi
}

invoke_ssh_script_output() {
  local user="$1"
  local server="$2"
  local port="${3:-22}"
  local timeout="${4:-20}"
  local script="$5"

  local args=(
    -p "$port"
    -o PreferredAuthentications=publickey,password
    -o "ConnectTimeout=$timeout"
    -o StrictHostKeyChecking=accept-new
    "$user@$server"
    "set -euo pipefail; $script"
  )

  local output
  if ! output="$(ssh "${args[@]}")"; then
    new_error "ssh exited with code $?"
  fi
  printf '%s' "$output"
}

copy_remote_script() {
  local local_path="$1"
  local remote_path="$2"
  local user="$3"
  local server="$4"
  local port="${5:-22}"
  local timeout="${6:-20}"

  require_cmd scp
  local temp
  temp="$(mktemp)"
  normalize_newlines "$local_path" "$temp"

  local args=(
    -P "$port"
    -o StrictHostKeyChecking=accept-new
    -o "ConnectTimeout=$timeout"
    "$temp"
    "$user@$server:$remote_path"
  )

  if ! scp "${args[@]}"; then
    rm -f "$temp"
    new_error "scp exited with code $?"
  fi
  rm -f "$temp"
}

install_public_key_remote() {
  local user="$1"
  local server="$2"
  local port="${3:-22}"
  local timeout="${4:-20}"
  local public_key_path="$5"

  local pub_key
  pub_key="$(tr -d '\r' <"$public_key_path" | tr -d '\n')"
  local escaped_pub
  escaped_pub="$(escape_squotes "$pub_key")"

  local remote_cmd="
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    touch ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
    grep -qxF '$escaped_pub' ~/.ssh/authorized_keys || echo '$escaped_pub' >> ~/.ssh/authorized_keys
  "

  local args=(
    -p "$port"
    -o PreferredAuthentications=password
    -o PubkeyAuthentication=no
    -o StrictHostKeyChecking=accept-new
    -o "ConnectTimeout=$timeout"
    "$user@$server"
    "$remote_cmd"
  )

  if ! ssh "${args[@]}"; then
    new_error "failed to install SSH key (ssh exited with $?)"
  fi
}

initialize_remote_task_scripts() {
  local user="$1"
  local server="$2"
  local port="$3"
  local timeout="$4"
  local remote_tasks_dir="$5"
  local local_tasks_dir="$6"

  invoke_ssh_script "$user" "$server" "$port" "$timeout" "mkdir -p '$remote_tasks_dir'"

  for script in "$local_tasks_dir"/*; do
    [ -f "$script" ] || continue
    local remote_path="$remote_tasks_dir/$(basename "$script")"
    copy_remote_script "$script" "$remote_path" "$user" "$server" "$port" "$timeout"
  done
}

test_remote_compose_present() {
  local user="$1"
  local server="$2"
  local port="$3"
  local timeout="$4"
  local remote_tasks_dir="$5"
  local remote_dir="$6"
  local check_script="$7"

  local cmd="cd '$remote_tasks_dir' && chmod +x '$check_script' && REMOTE_DIR='$(escape_squotes "$remote_dir")' bash '$check_script'"
  local output
  output="$(invoke_ssh_script_output "$user" "$server" "$port" "$timeout" "$cmd")"
  if printf '%s' "$output" | grep -q 'present'; then
    return 0
  fi
  return 1
}

stop_remote_compose() {
  local user="$1"
  local server="$2"
  local port="$3"
  local timeout="$4"
  local remote_tasks_dir="$5"
  local remote_dir="$6"
  local shutdown_script="$7"
  local sudo_password="$8"

  local env_assignments=()
  env_assignments+=("REMOTE_DIR='$(escape_squotes "$remote_dir")'")
  if [ -n "$sudo_password" ]; then
    env_assignments+=("SUDO_PASSWORD='$(escape_squotes "$sudo_password")'")
  fi

  local env_prefix
  env_prefix="$(printf '%s ' "${env_assignments[@]}")"
  local cmd="cd '$remote_tasks_dir' && chmod +x '$shutdown_script' && ${env_prefix}bash '$shutdown_script'"
  invoke_ssh_script "$user" "$server" "$port" "$timeout" "$cmd"
}

test_remote_sudo() {
  local user="$1"
  local server="$2"
  local port="$3"
  local timeout="$4"
  local remote_tasks_dir="$5"
  local sudo_password="$6"
  local check_script="$7"
  local max_attempts="${8:-3}"

  local attempt=1
  local password="$sudo_password"
  while [ "$attempt" -le "$max_attempts" ]; do
    local env_prefix="SUDO_PASSWORD='$(escape_squotes "$password")'"
    local cmd="cd '$remote_tasks_dir' && chmod +x '$check_script' && ${env_prefix} bash '$check_script'"
    local result
    result="$(invoke_ssh_script_output "$user" "$server" "$port" "$timeout" "$cmd")"

    if printf '%s' "$result" | grep -q '^ok:'; then
      printf '%s' "$password"
      return 0
    fi

    if printf '%s' "$result" | grep -q 'not_in_sudoers'; then
      new_error "User is not in sudoers. Aborting."
    fi
    if printf '%s' "$result" | grep -q 'missing_sudo'; then
      new_error "sudo is not available on the remote host. Aborting."
    fi
    if printf '%s' "$result" | grep -q 'missing_password'; then
      new_error "Sudo password missing. Aborting."
    fi
    if printf '%s' "$result" | grep -q 'bad_password'; then
      if [ "$attempt" -lt "$max_attempts" ]; then
        log_warn "Incorrect sudo password. Please try again."
        password="$(read_secret "SUDO password")"
        attempt=$((attempt + 1))
        continue
      fi
      new_error "Incorrect sudo password. Aborting."
    fi

    new_error "Failed to validate sudo access (remote reported: $result). Aborting."
  done
}
