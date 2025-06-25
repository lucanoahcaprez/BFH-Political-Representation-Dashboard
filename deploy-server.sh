#!/bin/bash

# --- Git Bash Redirect for Windows CMD/Powershell ---
if [[ "$(uname -s)" == *"NT"* ]] || grep -qE "Windows|MINGW|MSYS" <<< "$OS" && [ -z "$GIT_BASH_LAUNCHED" ]; then
  GIT_BASH_PATH="/c/Program Files/Git/bin/bash.exe"

  if [ ! -f "$GIT_BASH_PATH" ]; then
    echo "Git Bash not found. Downloading and installing..."
    curl -LO https://github.com/git-for-windows/git/releases/download/v2.44.0.windows.1/Git-2.44.0-64-bit.exe
    echo "Launching installer..."
    start /wait "" Git-2.44.0-64-bit.exe /VERYSILENT /NORESTART
    echo "Please restart this script after Git Bash installation."
    exit 0
  else
    echo "Switching to Git Bash..."
    "$GIT_BASH_PATH" -c "GIT_BASH_LAUNCHED=1 bash $(realpath "$0")"
    exit 0
  fi
fi

# --- Constants ---
REPO_URL="https://github.com/damian-lienhart/political-representation-dashboard.git"
BRANCH="main"
ENV_FILE=".env.deploy"
DOCKER_COMPOSE_FILE="docker-compose.prod.yml"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- Platform Detection ---
OS="$(uname)"
IS_MAC=false
IS_LINUX=false
IS_WINDOWS=false

case "$OS" in
  Darwin*) IS_MAC=true ;;
  Linux*)  IS_LINUX=true ;;
  MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=true ;;
esac

# --- Install Dependencies ---
install_if_missing() {
  if ! command -v "$1" &> /dev/null; then
    echo -e "${YELLOW}Installing $1...${NC}"
    if $IS_MAC; then
      brew install "$2"
    elif $IS_LINUX; then
      sudo apt update && sudo apt install -y "$2"
    else
      echo -e "${RED}Automatic installation not supported for $1 on this platform.${NC}"
    fi
  else
    echo -e "${GREEN}$1 already installed.${NC}"
  fi
}

# --- Dependency Install ---
if $IS_MAC; then
  command -v brew >/dev/null || /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  install_if_missing colima colima
  install_if_missing docker docker
  install_if_missing docker-compose docker-compose
  
elif $IS_LINUX; then
  install_if_missing docker docker.io
  install_if_missing docker-compose docker-compose
fi

install_if_missing curl curl
install_if_missing git git
install_if_missing nginx nginx
install_if_missing certbot certbot

# --- Ask for and validate target directory path ---
while true; do
  read -e -p "Enter full absolute path for deployment directory [leave empty for: $HOME/political-dashboard]: " TARGET_DIR
  TARGET_DIR=${TARGET_DIR:-"$HOME/political-dashboard"}

  if [[ "$TARGET_DIR" =~ [^a-zA-Z0-9._/\ ~-] ]]; then
    echo -e "${RED}Invalid characters in path.${NC}"
    echo "Allowed: letters, numbers, dots (.), dashes (-), underscores (_), slashes (/), and spaces."
    continue
  fi

  mkdir -p "$TARGET_DIR" 2>/dev/null || {
    echo -e "${RED}Failed to create directory: $TARGET_DIR${NC}"
    continue
  }

  cd "$TARGET_DIR" || {
    echo -e "${RED}Cannot access directory: $TARGET_DIR${NC}"
    continue
  }

  if [ -d ".git" ]; then
    echo -e "${GREEN}Git repository already exists in target directory.${NC}"
    read -p "Pull latest changes from Git? [y/N]: " PULL
    if [[ "$PULL" =~ ^[Yy]$ ]]; then
      git pull origin "$BRANCH"
    fi
    break

  elif [ -z "$(ls -A .)" ]; then
    echo -e "${GREEN}Directory is empty. Cloning project...${NC}"
    git clone -b "$BRANCH" "$REPO_URL" . || exit 1
    break

  else
    echo -e "${YELLOW}Directory is not empty and not a Git repository.${NC}"
    read -p "Choose a subfolder name to clone the project into (e.g. 'dashboard-clone'): " NEW_SUBDIR
    if [[ -z "$NEW_SUBDIR" ]]; then
      echo -e "${RED}You must enter a subfolder name.${NC}"
      continue
    fi

    mkdir -p "$TARGET_DIR/$NEW_SUBDIR" || {
      echo -e "${RED}Could not create subfolder '$NEW_SUBDIR'. Try again.${NC}"
      continue
    }

    cd "$TARGET_DIR/$NEW_SUBDIR" || {
      echo -e "${RED}Failed to enter '$NEW_SUBDIR'.${NC}"
      continue
    }

    echo -e "${GREEN}Cloning project into subfolder '$NEW_SUBDIR'...${NC}"
    git clone -b "$BRANCH" "$REPO_URL" . || exit 1
    break
  fi
done

# --- Docker Daemon Check ---
echo "Checking if Docker is running..."
if ! docker info &>/dev/null; then
  echo -e "${YELLOW}Docker is not running.${NC}"
  if $IS_LINUX; then
    echo "Attempting to start Docker via systemctl..."
    sudo systemctl start docker
    sleep 3
  elif $IS_MAC; then
  echo "Starting Colima..."
  colima start
  export DOCKER_HOST=unix://$HOME/.colima/docker.sock
  echo "Waiting for Docker to become available..."
  echo "If this is taking to long, there could be a problem in the .docker folder. I you are sure you can delete this folder and start the script again. 
  while ! docker info &>/dev/null; do
    sleep 2
    echo -n "."
  done
  elif $IS_WINDOWS; then
  if ! command -v docker &> /dev/null; then
    echo -e "${YELLOW}Docker not found. Downloading Docker Desktop installer...${NC}"
    curl -L -o DockerDesktopInstaller.exe "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe"
    echo -e "${YELLOW}Please run DockerDesktopInstaller.exe manually to install Docker. If you need to restart your device, please start the script again after installing Docker Desktop${NC}"
    read -p "Press ENTER after installing Docker Desktop and starting it..."
  else
    echo -e "${YELLOW}Please make sure Docker Desktop is running.${NC}"
    read -p "Press ENTER once Docker is started..."
  fi

  if ! docker info &>/dev/null; then
    echo -e "${RED}Failed to start Docker. Please start it manually and retry.${NC}"
    exit 1
  fi
fi
fi

echo -e "${GREEN}Docker is running.${NC}"

# --- Fix for missing docker-credential-desktop (common with Colima on macOS) ---
if $IS_MAC; then
  DOCKER_CONFIG_FILE="$HOME/.docker/config.json"
  if [ -f "$DOCKER_CONFIG_FILE" ] && grep -q '"credsStore": *"desktop"' "$DOCKER_CONFIG_FILE"; then
    echo -e "${YELLOW}Fixing Docker config: removing 'docker-credential-desktop'...${NC}"
    # Remove the credsStore line safely
    sed -i.bak '/"credsStore": *"desktop"/d' "$DOCKER_CONFIG_FILE"
    echo -e "${GREEN}Docker config patched successfully. Restarting Colima...${NC}"
    colima stop && colima start
    echo "Waiting for Docker to become available again..."
    while ! docker info &>/dev/null; do
      sleep 2
      echo -n "."
    done
  fi
fi


# --- ENV Config ---
configure_env_file() {
  read -p "Enter your domain (leave empty or type 'localhost' to use http://localhost): " APP_DOMAIN
  APP_DOMAIN=$(echo "$APP_DOMAIN" | tr -d ' ') "

  while :; do
    read -p "Frontend port [leave empty for default: 8080]: " FRONTEND_PORT
    FRONTEND_PORT=${FRONTEND_PORT:-8080}
    if lsof -i TCP:$FRONTEND_PORT &>/dev/null; then
      echo -e "${RED}Port $FRONTEND_PORT is already in use. Please choose another.${NC}"
    else
      break
    fi
  done

echo ""
echo "Configure backend and database connection:"
echo "  (Just press ENTER to use the default value in brackets)"
echo ""

read -p "Backend port [default: 3000]: " BACKEND_PORT
BACKEND_PORT=${BACKEND_PORT:-3000}

read -p "Database port [default: 5432]: " DB_PORT
DB_PORT=${DB_PORT:-5432}

read -p "Postgres user [default: postgres]: " POSTGRES_USER
POSTGRES_USER=${POSTGRES_USER:-postgres}

echo ""
echo "Please choose a secure Postgres password. This will be stored in your local .env.deploy file."
read -p "Postgres password: " POSTGRES_PASSWORD
while [[ -z "$POSTGRES_PASSWORD" ]]; do
  echo "Password cannot be empty."
  read -p "Postgres password: " POSTGRES_PASSWORD
done

POSTGRES_DB="political_dashboard"

DATABASE_URL="postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@db:5432/${POSTGRES_DB}"

cat <<EOF > $ENV_FILE
APP_DOMAIN=$APP_DOMAIN
FRONTEND_PORT=$FRONTEND_PORT
BACKEND_PORT=$BACKEND_PORT
DB_PORT=$DB_PORT
POSTGRES_USER=$POSTGRES_USER
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=$POSTGRES_DB
DATABASE_URL=$DATABASE_URL
FRONTEND_IMAGE=political-dashboard-frontend
BACKEND_IMAGE=political-dashboard-backend
EOF

}

if [ ! -f "$ENV_FILE" ]; then
  echo "Creating $ENV_FILE..."
  configure_env_file
else
  echo "Using existing $ENV_FILE:"
  cat $ENV_FILE
  read -p "Edit it? [y/N]: " EDIT
  [[ "$EDIT" =~ ^[Yy]$ ]] && configure_env_file
fi

if [ ! -s "$ENV_FILE" ]; then
  echo -e "${RED}.env.deploy file is missing or empty. Exiting.${NC}"
  exit 1
fi

export $(grep -v '^#' $ENV_FILE | xargs)

# --- Docker Compose ---
echo "Running Docker Compose..."
docker-compose -f $DOCKER_COMPOSE_FILE --env-file $ENV_FILE down
docker-compose -f $DOCKER_COMPOSE_FILE --env-file $ENV_FILE build || {
  echo -e "${RED}Docker build failed. Check Dockerfile and try again.${NC}"
  exit 1
}
docker-compose -f $DOCKER_COMPOSE_FILE --env-file $ENV_FILE up -d || {
  echo -e "${RED}Docker up failed. Check logs above.${NC}"
  exit 1
}

if [[ "$APP_DOMAIN" == "" || "$APP_DOMAIN" == "localhost" ]]; then
  URL="http://localhost:$FRONTEND_PORT"
else
  URL="https://$APP_DOMAIN"
fi

echo -e "${GREEN}Deployment complete at $URL${NC}"

while true; do
  echo ""
  echo -e "${GREEN}Deployment is running.${NC} What would you like to do?"
  echo "1) Show container logs"
  echo "2) Open frontend in browser"
  echo "3) Stop and deep exit (Requires rerunning script)"
  echo "4) Restart containers"
  echo "5) Shallow Exit (closes terminal blocks $APP_DOMAIN)"
  read -p "Enter choice [1-5]: " CHOICE

  case "$CHOICE" in
    1)
      echo -e "${YELLOW}Showing live logs. Press Ctrl+C to return to menu.${NC}"
      docker-compose -f $DOCKER_COMPOSE_FILE --env-file $ENV_FILE logs -f || echo -e "${RED}Failed to show logs.${NC}"
      ;;
    2)
      echo "Opening $URL..."
      if $IS_MAC; then
        open "$URL"
      elif $IS_LINUX; then
        xdg-open "$URL" >/dev/null 2>&1 &
      elif $IS_WINDOWS; then
        start "$URL"
      else
        echo -e "${YELLOW}Please open $URL in your browser manually.${NC}"
      fi
      ;;
    3)
      echo -e "${YELLOW}Stopping and exiting...${NC}"
      docker-compose -f $DOCKER_COMPOSE_FILE --env-file $ENV_FILE down
      echo -e "${GREEN}Stopped.${NC}"
      exit 0
      ;;
    4)
      echo -e "${YELLOW}Restarting containers...${NC}"
      docker-compose -f $DOCKER_COMPOSE_FILE --env-file $ENV_FILE down
      docker-compose -f $DOCKER_COMPOSE_FILE --env-file $ENV_FILE up -d
      ;;
    5)
      echo -e "${GREEN}Leaving containers running. Bye!${NC}"
      exit 0
      ;;
    *)
      echo -e "${RED}Invalid choice. Please select 1-5.${NC}"
      ;;
  esac
done
