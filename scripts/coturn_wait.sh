#!/usr/bin/env bash
set -euo pipefail

HOST="127.0.0.1"
PORT="3478"
TRIES="50"
SLEEP_SEC="0.2"

i=0
while [ "$i" -lt "$TRIES" ]; do
  if timeout 1 bash -c "</dev/udp/${HOST}/${PORT}" >/dev/null 2>&1; then
    echo "coturn appears reachable at ${HOST}:${PORT}"
    exit 0
  fi
  i=$((i + 1))
  sleep "$SLEEP_SEC"
done

echo "coturn did not become reachable at ${HOST}:${PORT}" >&2
exit 1
