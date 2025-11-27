#!/usr/bin/env bash
set -euo pipefail

: "${REMOTE_DIR:?REMOTE_DIR is required}"
: "${BRANCH:?BRANCH is required}"
: "${REPO_URL:?REPO_URL is required}"

command -v git >/dev/null 2>&1 || { echo "git not found"; exit 1; }

mkdir -p "$REMOTE_DIR"
cd "$REMOTE_DIR"

if [ ! -d .git ]; then
  git clone -b "$BRANCH" "$REPO_URL" .
else
  git fetch origin "$BRANCH"
  git reset --hard "origin/$BRANCH"
fi
