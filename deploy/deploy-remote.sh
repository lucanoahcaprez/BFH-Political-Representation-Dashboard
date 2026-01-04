#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/util.sh"
source "$SCRIPT_DIR/lib/ssh.sh"

SHUTDOWN=false
CONNECT_TIMEOUT_SECONDS=20
print_deploy_header() {
  local divider="===================================================================="
  cat <<EOF
$divider
  Political Representation Dashboard - Remote Deployment
  Authors : Elia Bucher, Luca Noah Caprez, Pascal Feller (BFH student project)
  License : MIT (see LICENSE)
  Logs    : $SCRIPT_DIR/logs (per-run file announced below)
  Usage   : $(basename "$0") [--shutdown] [--connect-timeout SECONDS]
            --shutdown stops the existing remote docker-compose stack, then exits.
  Steps   :
    1) Check local SSH/scp prerequisites and reachability
    2) Prepare the remote host (helper scripts, packages, Docker)
    3) Sync project files and deployment env vars
    4) Deploy docker-compose and print URLs/log paths
$divider
EOF
}

prompt_required() {
  local message="$1"
  local default="${2:-}"
  local value=""
  while [ -z "$value" ]; do
    value="$(read_value "$message" "$default")"
    if [ -z "$value" ]; then
      log_warn "Please enter a value." >&2
    fi
  done
  printf '%s' "$value"
}

set_env_value() {
  local file="$1"
  local key="$2"
  local value="$3"

  # replace the key with the new value if exists, append if key not present
  if grep -qE "^${key}=" "$file" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}


print_usage() {
  cat <<EOF
Usage: $(basename "$0") [--shutdown] [--connect-timeout SECONDS] [--connect-delay SECONDS]
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --shutdown)
      SHUTDOWN=true
      shift
      ;;
    --connect-timeout)
      CONNECT_TIMEOUT_SECONDS="${2:-20}"
      shift 2
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      log_warn "Unknown argument: $1"
      print_usage
      exit 0
      ;;
  esac
done

print_deploy_header
log_info "Starting remote deployment script."

LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/deploy-remote-$(date +%Y%m%d-%H%M%S).log"
set_ui_log_file "$LOG_FILE"
set_ui_info_visibility true
log_info "Logging to $LOG_FILE"

REMOTE_TASKS_DIR="/tmp/pol-dashboard-tasks"
CHECK_SCRIPT_NAME="check_remote_compose.sh"
SHUTDOWN_SCRIPT_NAME="shutdown_remote_compose.sh"
CHECK_SUDO_SCRIPT_NAME="check_sudo.sh"
CHECK_PORT_SCRIPT_NAME="check_port_available.sh"
CHECK_OWNER_SCRIPT_NAME="check_owner_exists.sh"

on_error() {
  log_error "Deployment failed. Review $LOG_FILE for details."
}
trap 'on_error' ERR

get_app_url() {
  local env_path="$1"
  local default_port="${2:-8080}"
  local server="$3"

  local domain
  domain="$(read_env_value "$env_path" "APP_DOMAIN")"
  local frontend_port
  frontend_port="$(read_env_value "$env_path" "FRONTEND_PORT")"
  [ -n "$frontend_port" ] || frontend_port="$default_port"

  if [ -z "$domain" ] || [ "$domain" = "localhost" ]; then
    if [ -n "$server" ]; then
      echo "http://$server:$frontend_port"
    else
      echo "http://localhost:$frontend_port"
    fi
  else
    echo "https://$domain"
  fi
}

invoke_deployment_sync() {
  local method="$1"
  local user="$2"
  local server="$3"
  local port="$4"
  local remote_dir="$5"
  local deploy_root="$6"
  local env_file="$7"

  local strategy_path="$deploy_root/sync_strategies/${method}.sh"
  if [ ! -f "$strategy_path" ]; then
    new_error "Unsupported deployment method '$method' (missing $strategy_path)"
  fi

  unset -f invoke_sync_strategy 2>/dev/null || true
  # shellcheck disable=SC1090
  source "$strategy_path"

  if ! command -v invoke_sync_strategy >/dev/null 2>&1; then
    new_error "Sync strategy '$method' missing entrypoint invoke_sync_strategy"
  fi

  invoke_sync_strategy "$user" "$server" "$port" "$remote_dir" "$deploy_root" "$env_file"
}

ensure_frontend_port_available() {
  local env_path="$1"
  local existing_compose="$2"

  local frontend_port
  frontend_port="$(read_env_value "$env_path" "FRONTEND_PORT")"
  [ -n "$frontend_port" ] || frontend_port="8080"

  while true; do
    local result
    result="$(check_remote_port_available "$ssh_user" "$ssh_host" "$ssh_port" "$CONNECT_TIMEOUT_SECONDS" "$REMOTE_TASKS_DIR" "$frontend_port" "$CHECK_PORT_SCRIPT_NAME" "$sudo_password")"
    if printf '%s' "$result" | grep -q '^available'; then
      log_success "Frontend port $frontend_port is available on $ssh_host."
      return
    fi

    if printf '%s' "$result" | grep -q '^error:'; then
      log_warn "Could not verify port availability on $ssh_host (response: $result)."
      if confirm_action "Continue with port $frontend_port anyway?"; then
        return
      fi
    else
      local detail="${result#in_use:}"
      log_warn "Port $frontend_port is already in use on $ssh_host."
      if [ -n "$detail" ]; then
        log_info "Socket info: $detail"
      fi

      if [ "$existing_compose" = true ]; then
        local choice
        choice="$(read_choice "Options: reuse (only choose reuse if you have already deployed this web application once. if not choose an other port), choose-new, cancel" "reuse" "choose-new" "cancel")"
        case "$choice" in
          reuse)
            log_info "Reusing port $frontend_port even though it is already bound."
            return
            ;;
          cancel)
            log_warn "Deployment cancelled by user."
            exit 0
            ;;
          choose-new)
            ;;
        esac
      else
        log_info "Port $frontend_port is occupied. Choose a different port to avoid conflicts."
      fi
    fi

    frontend_port="$(prompt_required "Enter a new frontend port" "$frontend_port")"
    set_env_value "$env_path" "FRONTEND_PORT" "$frontend_port"
    log_info "Updated FRONTEND_PORT in $env_path to $frontend_port. Rechecking on remote host..."
  done
}

ensure_remote_owner_exists() {
  local owner_user="$1"
  local owner_group="$2"

  local env_prefix
  env_prefix="REMOTE_OWNER_USER='$(escape_squotes "$owner_user")' REMOTE_OWNER_GROUP='$(escape_squotes "$owner_group")'"
  local cmd="cd '$REMOTE_TASKS_DIR' && chmod +x '$CHECK_OWNER_SCRIPT_NAME' && ${env_prefix} bash '$CHECK_OWNER_SCRIPT_NAME'"
  local result
  result="$(invoke_ssh_script_output "$ssh_user" "$ssh_host" "$ssh_port" "$CONNECT_TIMEOUT_SECONDS" "$cmd")"

  if printf '%s' "$result" | grep -q '^ok:'; then
    return 0
  fi

  if printf '%s' "$result" | grep -q '^missing_user:'; then
    log_warn "Remote user '$owner_user' does not exist on $ssh_host." >&2
  fi
  if printf '%s' "$result" | grep -q '^missing_group:'; then
    log_warn "Remote group '$owner_group' does not exist on $ssh_host." >&2
  fi
  if ! printf '%s' "$result" | grep -qE '^missing_(user|group):'; then
    log_warn "Could not validate remote owner on $ssh_host (response: $result)" >&2
  fi
  return 1
}

# 1) Check dependencies
log_info "Check local prerequisites (ssh, scp, ssh-keygen) on $(hostname)"
require_cmd ssh
require_cmd scp
require_cmd ssh-keygen

# 2) Ask for SSH connection details
section "Connection"
ssh_host="$(prompt_required "Remote host (IP-address or domain name)")"
port_input="$(read_value "SSH port" "22")"
ssh_port="${port_input:-22}"
ssh_user="$(prompt_required "SSH user")"
is_root_user=false
if [ "$ssh_user" = "root" ]; then
  is_root_user=true
fi

# 3) Try SSH with an existing key first; only install/generate on fallback.
default_key_path="$HOME/.ssh/id_ed25519"
pub_key_path="$default_key_path.pub"
connected_with_key=false

if [ -f "$default_key_path" ] && [ -f "$pub_key_path" ]; then
  log_info "Testing ssh connection with existing key at $default_key_path"
  if test_ssh_connection "$ssh_user" "$ssh_host" "$ssh_port" "$CONNECT_TIMEOUT_SECONDS" "publickey"; then
    connected_with_key=true
  fi
fi

if [ "$connected_with_key" != true ]; then
  log_info "SSH key authentication not available; falling back to password to install key."
  log_info "Ensure local sshkey is present"
  pub_key_path="$(ensure_local_ssh_key)"
  log_info "Try to install public-key on $ssh_host"
  install_public_key_remote "$ssh_user" "$ssh_host" "$ssh_port" "$CONNECT_TIMEOUT_SECONDS" "$pub_key_path"

  log_info "Testing ssh connection with key after install"
  if ! test_ssh_connection "$ssh_user" "$ssh_host" "$ssh_port" "$CONNECT_TIMEOUT_SECONDS" "publickey"; then
    log_error "SSH connection failed after key install. Aborting."
    exit 1
  fi
  log_success "SSH connection with key OK."
else
  log_success "SSH connection with existing key OK."
fi

# 5) Copy all necessary remote task scripts
log_info "Create remote task directory ($REMOTE_TASKS_DIR)"
invoke_ssh_script "$ssh_user" "$ssh_host" "$ssh_port" "$CONNECT_TIMEOUT_SECONDS" "mkdir -p '$REMOTE_TASKS_DIR'"
log_info "Copy remote tasks to $REMOTE_TASKS_DIR"
initialize_remote_task_scripts "$ssh_user" "$ssh_host" "$ssh_port" "$CONNECT_TIMEOUT_SECONDS" "$REMOTE_TASKS_DIR" "$SCRIPT_DIR/ssh_tasks"

# 6) Prompt for further informations (skip sudo when connecting as root)
sudo_password=""
if [ "$is_root_user" = false ]; then
  section "Sudo access"
  log_info "Needed to install packages and manage Docker on the remote host."
  while [ -z "$sudo_password" ]; do
    sudo_password="$(read_secret "Remote sudo password")"
    if [ -z "$sudo_password" ]; then
      log_warn "Password cannot be empty. Please enter a value."
    fi
  done
  sudo_password="$(test_remote_sudo "$ssh_user" "$ssh_host" "$ssh_port" "$CONNECT_TIMEOUT_SECONDS" "$REMOTE_TASKS_DIR" "$sudo_password" "$CHECK_SUDO_SCRIPT_NAME")"
  sudo_password="${sudo_password//$'\r'/}"   # remove CR
  sudo_password="${sudo_password//$'\n'/}"   # remove LF
  printf "\n"
  log_success "SUDO password ok."
else
  log_info "Connected as root; skipping sudo password prompt."
fi

remote_owner_user=""
remote_owner_group=""
section "Ownership"
if confirm_action "Use a different user/group to own the remote deploy directory?"; then
  while true; do
    remote_owner_user="$(prompt_required "Remote owner user")"
    remote_owner_group="$(prompt_required "Remote owner group")"
    log_info "Validating remote user/group on $ssh_host..."
    if ensure_remote_owner_exists "$remote_owner_user" "$remote_owner_group"; then
      log_success "Remote ownership will be set to ${remote_owner_user}:${remote_owner_group}."
      break
    fi

    if ! confirm_action "User or group missing on remote. Enter values again?"; then
      log_error "Remote ownership validation failed. Aborting."
      exit 1
    fi
  done
else
  log_info "Using SSH user for remote directory ownership."
fi

# 7) Prompt for remote directory and optional shutdown
section "Remote target"
log_info "Choose remote deploy directory. Thats where your web application files will live. We create the directory for you if it is missing."
remote_dir="$(read_value "Remote deploy directory (created if missing)" "/opt/political-dashboard")"
log_info "Prepare remote helper directory $REMOTE_TASKS_DIR"

# 8) Check if user wants to shutdown existing docker stack
if [ "$SHUTDOWN" = true ]; then
  section "Shutdown"
  log_info "Checking for existing docker-compose files in $remote_dir"
  if test_remote_compose_present "$ssh_user" "$ssh_host" "$ssh_port" "$CONNECT_TIMEOUT_SECONDS" "$REMOTE_TASKS_DIR" "$remote_dir" "$CHECK_SCRIPT_NAME"; then
    log_info "Stopping existing docker-compose stack in $remote_dir"
    stop_remote_compose "$ssh_user" "$ssh_host" "$ssh_port" "$CONNECT_TIMEOUT_SECONDS" "$REMOTE_TASKS_DIR" "$remote_dir" "$SHUTDOWN_SCRIPT_NAME" "$sudo_password"
    log_success "Remote docker-compose stack stopped."
  else
    log_info "No docker-compose files found in $remote_dir"
  fi
  log_success "Shutdown flag completed. Exiting."
  exit 0
fi

# 9) Create/update local .env.deploy
section "Environment file"
log_info "In docker-compose, an environment file centralizes configuration like ports, domains, and credentials so containers stay configurable without editing compose YAML."
log_info "We will create .env.deploy locally and copy it alongside the application files on the remote host so the stack reads consistent settings."
log_info "Step: Create or confirm deployment environment values (.env.deploy)"
log_info "Action: confirm defaults or customize ports/app domain used by docker-compose."
use_env_defaults=false
if confirm_action "Use default environment values (frontend port '8080', postgres user 'postgres')?"; then
  use_env_defaults=true
fi
env_creator="$SCRIPT_DIR/tasks/create_env.sh"
if [ "$use_env_defaults" = true ]; then
  "$env_creator" --use-defaults
else
  "$env_creator"
fi
env_deploy_path="$PWD/.env.deploy"
if [ ! -f "$env_deploy_path" ]; then
  env_deploy_path="$SCRIPT_DIR/.env.deploy"
fi

# 10) Ask deployment method (local only for now)
# TODO: cleanup
# method="$(read_choice "Step: Deployment method? [local]" "local")"
# log_info "Selected method: $method"

method="local"
has_existing_compose=false
if test_remote_compose_present "$ssh_user" "$ssh_host" "$ssh_port" "$CONNECT_TIMEOUT_SECONDS" "$REMOTE_TASKS_DIR" "$remote_dir" "$CHECK_SCRIPT_NAME"; then
  has_existing_compose=true
fi

ensure_frontend_port_available "$env_deploy_path" "$has_existing_compose"

if [ "$has_existing_compose" = true ]; then
  section "Existing deployment found"
  log_info "We found an already existing docker stack in $remote_dir. You can choose if you want to redeploy with the current files or cancel the deployment"
  action="$(read_choice "Type 'redeploy' or 'cancel'" "redeploy" "cancel")"
  if [ "$action" = "cancel" ]; then
    log_warn "Deployment cancelled by user."
    exit 0
  fi
fi

# 11) Prepare remote host
section "Prepare remote host"
log_info "Installing prerequisites (docker, docker-compose, curl, git) if necessary. This may take up to 2 minutes. Please wait..."
cmd_env=("REMOTE_DIR='$(escape_squotes "$remote_dir")'")
if [ "$is_root_user" = false ]; then
  cmd_env+=("SUDO_PASSWORD='$(escape_squotes "$sudo_password")'")
fi

prep_cmd="cd '$REMOTE_TASKS_DIR' && chmod +x 'prepare_remote.sh' && ${cmd_env[*]} bash 'prepare_remote.sh'"
invoke_ssh_script "$ssh_user" "$ssh_host" "$ssh_port" "$CONNECT_TIMEOUT_SECONDS" "$prep_cmd"
log_success "Remote preparation complete."

# 12) Sync project using selected strategy
section "Sync and deploy"
invoke_deployment_sync "$method" "$ssh_user" "$ssh_host" "$ssh_port" "$remote_dir" "$SCRIPT_DIR" "$env_deploy_path"
log_success "Sync via '$method' completed."
set_ui_log_file "$LOG_FILE"
# 13) Deploy application on remote host
if [ -n "$remote_owner_user" ]; then
  cmd_env+=("REMOTE_OWNER_USER='$(escape_squotes "$remote_owner_user")'")
fi
if [ -n "$remote_owner_group" ]; then
  cmd_env+=("REMOTE_OWNER_GROUP='$(escape_squotes "$remote_owner_group")'")
fi
deploy_cmd="cd '$REMOTE_TASKS_DIR' && chmod +x 'deploy.sh' && ${cmd_env[*]} bash 'deploy.sh'"
log_info "Deploy docker stack on remote machine in $remote_dir. This may take 2-3 minutes while containers build/start. Please wait..."
invoke_ssh_script "$ssh_user" "$ssh_host" "$ssh_port" "$CONNECT_TIMEOUT_SECONDS" "$deploy_cmd"
log_success "Remote deploy executed."

# 14) Surface useful info to the user
section "Summary"
remote_log_dir="/var/log/political-dashboard"
app_url="$(get_app_url "$env_deploy_path" "8080" "$ssh_host")"

log_info "$(cat <<EOF

  Project files  : $ssh_host:$remote_dir
  Remote logs    : $ssh_host:$remote_log_dir/prepare_remote.log and deploy.log
  Local log file : $LOG_FILE
  Application    : $app_url
Rerun this script anytime; use --shutdown to stop and remove the remote docker-compose stack.
EOF
)"
