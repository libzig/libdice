#!/usr/bin/env bash
set -euo pipefail

NAME="libdice-coturn"

if docker ps -a --format '{{.Names}}' | grep -q "^${NAME}$"; then
  docker rm -f "${NAME}" >/dev/null
  echo "coturn removed: ${NAME}"
else
  echo "coturn not found: ${NAME}"
fi
