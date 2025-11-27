#!/usr/bin/env bash
set -euo pipefail

: "${REMOTE_DIR:?REMOTE_DIR is required}"

mkdir -p "$REMOTE_DIR"
