#!/usr/bin/env bash
set -euo pipefail

IMAGE="zoomfixer-sandbox"
CONTAINER="zoomfixer-sandbox"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTEXT="${SCRIPT_DIR}/../Docker"

log() { printf "[%s] %s\n" "$(date +"%H:%M:%S")" "$*"; }

if ! command -v docker >/dev/null 2>&1; then
  log "Docker is required but not installed."
  exit 1
fi

if [ ! -f "${CONTEXT}/Dockerfile" ]; then
  log "Dockerfile not found at ${CONTEXT}"
  exit 1
fi

log "Building image ${IMAGE}"
docker image inspect "${IMAGE}" >/dev/null 2>&1 || docker build -t "${IMAGE}" "${CONTEXT}"

log "Stopping previous container (if any)"
docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true

log "Starting sandbox container"
docker run -d --rm \
  --name "${CONTAINER}" \
  -p 5901:5901 \
  -p 6080:6080 \
  -v zoomfixer_home:/home/zoomuser \
  "${IMAGE}"

log "Container is running."
log "Connect via browser (noVNC): http://localhost:6080/vnc.html"
log "Or VNC client: localhost:5901 (no password)"
