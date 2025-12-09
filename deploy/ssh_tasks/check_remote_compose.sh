#!/usr/bin/env bash
set -euo pipefail

: "${REMOTE_DIR:?REMOTE_DIR must be set}"

if [ -f "$REMOTE_DIR/docker-compose.yml" ] || [ -f "$REMOTE_DIR/docker-compose.prod.yml" ]; then
  echo "present"
else
  echo "absent"
fi
