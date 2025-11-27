#!/usr/bin/env bash
set -euo pipefail

: "${REMOTE_DIR:?REMOTE_DIR is required}"
: "${ARCHIVE_PATH:?ARCHIVE_PATH is required}"

tmpdir="$REMOTE_DIR/.deploy_tmp"

mkdir -p "$REMOTE_DIR"
rm -rf "$REMOTE_DIR.old"
rm -rf "$tmpdir"
mkdir -p "$tmpdir"

tar -xzf "$ARCHIVE_PATH" -C "$tmpdir"

if [ -d "$REMOTE_DIR" ]; then
  mv "$REMOTE_DIR" "$REMOTE_DIR.old"
fi

mv "$tmpdir" "$REMOTE_DIR"
rm -f "$ARCHIVE_PATH"
