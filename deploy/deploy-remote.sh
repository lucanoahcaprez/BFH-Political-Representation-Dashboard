#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/util.sh"
source "$SCRIPT_DIR/lib/ssh.sh"

SHUTDOWN=false
CONNECT_TIMEOUT_SECONDS=20
CONNECT_DELAY_SECONDS=1

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
    --connect-delay)
      CONNECT_DELAY_SECONDS="${2:-1}"
      shift 2
      ;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [--shutdown] [--connect-timeout SECONDS] [--connect-delay SECONDS]
EOF
      exit 0
      ;;
    *)
      log_warn "Ignoring unknown argument: $1"
      shift
      ;;
  esac
done

LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/deploy-remote-$(date +%Y%m%d-%H%M%S).log"
set_ui_log_file "$LOG_FILE"
set_ui_info_visibility true
log_success "Logging deployment details to $LOG_FILE"

REMOTE_TASKS_DIR="/tmp/pol-dashboard-tasks"
CHECK_SCRIPT_NAME="check_remote_compose.sh"
SHUTDOWN_SCRIPT_NAME="shutdown_remote_compose.sh"
CHECK_SUDO_SCRIPT_NAME="check_sudo.sh"

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

# 1) Check dependencies
log_info "Checking dependency on $(hostname)"
require_cmd ssh
require_cmd scp
require_cmd ssh-keygen

# 2) Ask for SSH connection details
log_info "Read connection details for ssh"
ssh_host="$(read_value "SSH host")"
port_input="$(read_value "SSH port" "22")"
ssh_port="${port_input:-22}"
ssh_user="$(read_value "SSH user")"

# 3) Ensure keypair locally and install pubkey remotely (one-time password)
log_info "Ensure local sshkey is present"
pub_key_path="$(ensure_local_ssh_key)"
log_info "Try to install public-key on $ssh_host"
install_public_key_remote "$ssh_user" "$ssh_host" "$ssh_port" "$CONNECT_TIMEOUT_SECONDS" "$pub_key_path"

# 4) Test SSH connectivity (should use key now)
log_info "Testing ssh connection with key"
if ! test_ssh_connection "$ssh_user" "$ssh_host" "$ssh_port" "$CONNECT_TIMEOUT_SECONDS"; then
  log_error "SSH connection failed after key install. Aborting."
  exit 1
fi
log_success "SSH connection with key OK."

# 5) Copy all necessary remote task scripts
log_info "Create remote task directory ($REMOTE_TASKS_DIR)"
invoke_ssh_script "$ssh_user" "$ssh_host" "$ssh_port" "$CONNECT_TIMEOUT_SECONDS" "mkdir -p '$REMOTE_TASKS_DIR'"
log_info "Copy remote tasks to $REMOTE_TASKS_DIR"
initialize_remote_task_scripts "$ssh_user" "$ssh_host" "$ssh_port" "$CONNECT_TIMEOUT_SECONDS" "$REMOTE_TASKS_DIR" "$SCRIPT_DIR/ssh_tasks"

# 6) Prompt for further informations
log_info "Prompting for further informations"
sudo_password=""
while [ -z "$sudo_password" ]; do
  sudo_password="$(read_secret "SUDO password")"
  if [ -z "$sudo_password" ]; then
    log_warn "Password cannot be empty. Please enter a value."
  fi
done
sudo_password="$(test_remote_sudo "$ssh_user" "$ssh_host" "$ssh_port" "$CONNECT_TIMEOUT_SECONDS" "$REMOTE_TASKS_DIR" "$sudo_password" "$CHECK_SUDO_SCRIPT_NAME")"
log_success "SUDO password ok."

# 7) Prompt for remote directory and optional shutdown
remote_dir="$(read_value "Remote deploy directory" "/opt/political-dashboard")"
log_info "Prepare remote helper directory $REMOTE_TASKS_DIR"

# 8) Check if user wants to shutdown existing docker stack
if [ "$SHUTDOWN" = true ]; then
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
log_info "Gather input for creation of .env.deploy"
use_env_defaults=false
if confirm_action "Use default environment values (ports 8080/3000/5432, postgres user)?"; then
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
method="$(read_choice "Deployment method? [local]" "local")"
log_info "Selected method: $method"

has_existing_compose=false
if test_remote_compose_present "$ssh_user" "$ssh_host" "$ssh_port" "$CONNECT_TIMEOUT_SECONDS" "$REMOTE_TASKS_DIR" "$remote_dir" "$CHECK_SCRIPT_NAME"; then
  has_existing_compose=true
fi

if [ "$has_existing_compose" = true ]; then
  action="$(read_choice "Existing docker-compose found in $remote_dir. [redeploy|cancel]" "redeploy" "cancel")"
  if [ "$action" = "cancel" ]; then
    log_warn "Deployment cancelled by user."
    exit 0
  fi
fi

# 11) Prepare remote host
log_info "Prepare remote host"
prep_cmd="cd '$REMOTE_TASKS_DIR' && chmod +x 'prepare_remote.sh' && REMOTE_DIR='$(escape_squotes "$remote_dir")' SUDO_PASSWORD='$(escape_squotes "$sudo_password")' bash 'prepare_remote.sh'"
log_info "Prepare remote: running prepare_remote.sh on $ssh_host"
invoke_ssh_script "$ssh_user" "$ssh_host" "$ssh_port" "$CONNECT_TIMEOUT_SECONDS" "$prep_cmd"
log_success "Remote preparation complete."

# 12) Sync project using selected strategy
invoke_deployment_sync "$method" "$ssh_user" "$ssh_host" "$ssh_port" "$remote_dir" "$SCRIPT_DIR" "$env_deploy_path"
log_success "Sync via '$method' completed."

# 13) Deploy application on remote host
deploy_cmd="cd '$REMOTE_TASKS_DIR' && chmod +x 'deploy.sh' && REMOTE_DIR='$(escape_squotes "$remote_dir")' SUDO_PASSWORD='$(escape_squotes "$sudo_password")' bash 'deploy.sh'"
invoke_ssh_script "$ssh_user" "$ssh_host" "$ssh_port" "$CONNECT_TIMEOUT_SECONDS" "$deploy_cmd"
log_success "Remote deploy executed."

# 14) Surface useful info to the user
remote_log_dir="/var/log/political-dashboard"
app_url="$(get_app_url "$env_deploy_path" "8080" "$ssh_host")"

log_success "Local log file: $LOG_FILE"
log_success "Remote logs: $remote_log_dir/prepare_remote.log, $remote_log_dir/deploy.log (host: $ssh_host)"
log_success "Application URL: $app_url"
