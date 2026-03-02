#!/usr/bin/env bash
set -euo pipefail

NAME="libdice-coturn"
IMAGE="coturn/coturn:4.6.2"
PORT="3478"
REALM="libdice.local"
USER="test"
PASS="testpass"

if docker ps --format '{{.Names}}' | grep -q "^${NAME}$"; then
  echo "coturn already running: ${NAME}"
  exit 0
fi

if docker ps -a --format '{{.Names}}' | grep -q "^${NAME}$"; then
  docker rm -f "${NAME}" >/dev/null
fi

docker run -d --name "${NAME}" \
  -p "${PORT}:${PORT}/udp" \
  --restart unless-stopped \
  "${IMAGE}" \
  -n \
  --log-file=stdout \
  --realm "${REALM}" \
  --user "${USER}:${PASS}" \
  --lt-cred-mech \
  --fingerprint \
  --no-cli \
  --no-tls \
  --no-dtls \
  --listening-port "${PORT}"

echo "coturn started: ${NAME}"
echo "server: 127.0.0.1:${PORT}"
echo "realm: ${REALM}"
echo "username: ${USER}"
echo "password: ${PASS}"
