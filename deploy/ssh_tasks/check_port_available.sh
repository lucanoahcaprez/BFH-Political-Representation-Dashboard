#!/usr/bin/env bash
set -euo pipefail

: "${REMOTE_PORT:?REMOTE_PORT must be set}"

PORT="$REMOTE_PORT"

run_ss() {
  if [ -n "${SUDO_PASSWORD:-}" ]; then
    # -S reads the password from stdin; -p '' suppresses the prompt.
    echo "$SUDO_PASSWORD" | sudo -S -p '' ss -H -l -n -t -u -p
  else
    ss -H -l -n -t -u -p
  fi
}

output=""
if ! output="$(run_ss 2>/dev/null)"; then
  echo "error:ss_failed"
  exit 0
fi

match="$(printf '%s\n' "$output" | awk -v port=":$PORT" '$5 ~ port"$" { print; exit }')"
if [ -n "$match" ]; then
  # Return a short, greppable marker followed by the first matching line.
  echo "in_use:$match"
  exit 0
fi

echo "available"
