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
log_info "Check local prerequisites (ssh, scp, ssh-keygen) on $(hostname)"
require_cmd ssh
require_cmd scp
require_cmd ssh-keygen

# 2) Ask for SSH connection details
section "Connection"
ssh_host="$(prompt_required "Remote host (IP or DNS)")"
port_input="$(read_value "SSH port" "22")"
ssh_port="${port_input:-22}"
ssh_user="$(prompt_required "SSH user (root skips sudo prompts)")"
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
  printf "\n"
  log_success "SUDO password ok."
else
  log_info "Connected as root; skipping sudo password prompt."
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
# TODO: cleanup
# method="$(read_choice "Step: Deployment method? [local]" "local")"
# log_info "Selected method: $method"

method="local"
has_existing_compose=false
if test_remote_compose_present "$ssh_user" "$ssh_host" "$ssh_port" "$CONNECT_TIMEOUT_SECONDS" "$REMOTE_TASKS_DIR" "$remote_dir" "$CHECK_SCRIPT_NAME"; then
  has_existing_compose=true
fi

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
log_info "Installing prerequisites (docker, docker-compose, curl, git) if necessary"
prep_cmd_env=("REMOTE_DIR='$(escape_squotes "$remote_dir")'")
if [ "$is_root_user" = false ]; then
  prep_cmd_env+=("SUDO_PASSWORD='$(escape_squotes "$sudo_password")'")
fi
prep_cmd="cd '$REMOTE_TASKS_DIR' && chmod +x 'prepare_remote.sh' && ${prep_cmd_env[*]} bash 'prepare_remote.sh' > /dev/null 2>&1"
log_info "Prepare remote: running prepare_remote.sh quietly (details in $LOG_FILE)"
invoke_ssh_script "$ssh_user" "$ssh_host" "$ssh_port" "$CONNECT_TIMEOUT_SECONDS" "$prep_cmd"
log_success "Remote preparation complete."

# 12) Sync project using selected strategy
section "Sync and deploy"
invoke_deployment_sync "$method" "$ssh_user" "$ssh_host" "$ssh_port" "$remote_dir" "$SCRIPT_DIR" "$env_deploy_path"
log_success "Sync via '$method' completed."

# 13) Deploy application on remote host
deploy_cmd_env=("REMOTE_DIR='$(escape_squotes "$remote_dir")'")
if [ "$is_root_user" = false ]; then
  deploy_cmd_env+=("SUDO_PASSWORD='$(escape_squotes "$sudo_password")'")
fi
deploy_cmd="cd '$REMOTE_TASKS_DIR' && chmod +x 'deploy.sh' && ${deploy_cmd_env[*]} bash 'deploy.sh' > /dev/null 2>&1"
log_info "Deploy docker stack on remote machine in $remote_dir"
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
