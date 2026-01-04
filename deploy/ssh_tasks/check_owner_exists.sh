#!/usr/bin/env bash
set -euo pipefail

: "${REMOTE_OWNER_USER:?REMOTE_OWNER_USER must be set}"
: "${REMOTE_OWNER_GROUP:?REMOTE_OWNER_GROUP must be set}"

missing=()

if ! id -u "$REMOTE_OWNER_USER" >/dev/null 2>&1; then
  missing+=("missing_user:$REMOTE_OWNER_USER")
fi

# Prefer getent; fall back to /etc/group to avoid false negatives on minimal systems.
if getent group "$REMOTE_OWNER_GROUP" >/dev/null 2>&1; then
  :
elif cut -d: -f1 /etc/group 2>/dev/null | grep -Fx "$REMOTE_OWNER_GROUP" >/dev/null 2>&1; then
  :
else
  missing+=("missing_group:$REMOTE_OWNER_GROUP")
fi

if [ "${#missing[@]}" -eq 0 ]; then
  echo "ok:$REMOTE_OWNER_USER:$REMOTE_OWNER_GROUP"
  exit 0
fi

printf '%s\n' "${missing[@]}"
exit 0
