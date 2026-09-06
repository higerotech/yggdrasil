#!/usr/bin/env bash
# Sincroniza el clon del repositorio (bind mount en /repo) con el commit que despliega el receptor
# (IMAGE_TAG=sha-<7>), renderiza las plantillas y recarga los servicios. Dos modos porque un
# contenedor no puede estar a la vez en host-mode y en la red interna de Compose:
#   host  (network_mode: host)  checkout + render (lee las IPs de wan1/wan2) + recarga blackbox
#   net   (red heimdall)        recarga Mimir y Gjallarhorn por HTTP
set -euo pipefail
MODO="${1:-host}"
DIR="${YGG_DIR:-/repo}"
TAG="${IMAGE_TAG:?IMAGE_TAG es obligatorio (sha-<7>)}"
SHA="${TAG#sha-}"
REMOTO="${YGG_REPO_URL:-https://github.com/higerotech/yggdrasil.git}"
log() { echo "$(date -Iseconds) sync[$MODO]: $*"; }
recargar() { # $1 nombre, $2 url
  if curl -fsS -m 8 -X POST "$2" >/dev/null 2>&1; then log "$1 recargado"; else log "$1 no recargado (aún no arrancado o sin cambios)"; fi
}

case "$MODO" in
  host)
    cd "$DIR"
    git config --global --add safe.directory "$DIR"
    if [ ! -d .git ]; then log "clon inicial de $REMOTO"; git clone --quiet "$REMOTO" .; fi
    git fetch --quiet origin main
    git checkout --quiet --detach "$SHA" || { log "commit $SHA no está en origin/main"; exit 1; }
    log "checkout $(git rev-parse --short HEAD): $(git log -1 --format=%s)"
    if [ ! -f deploy/.env ]; then log "falta deploy/.env; no se renderiza (ejecutar bootstrap-midgard.sh)"; exit 1; fi
    (cd deploy && ./scripts/render.sh --sin-recarga)
    recargar "blackbox" "http://${DOCKER_HOST_GW:-172.17.0.1}:9115/-/reload"
    ;;
  net)
    recargar "mimir" "http://mimir:9090/-/reload"
    recargar "gjallarhorn" "http://gjallarhorn:9093/-/reload"
    ;;
  *) log "modo desconocido: $MODO (host|net)"; exit 2 ;;
esac
log "listo"
