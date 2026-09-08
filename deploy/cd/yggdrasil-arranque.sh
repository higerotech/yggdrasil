#!/usr/bin/env bash
# Converge el stack de Yggdrasil tras un arranque del appliance (RNF02, caso TA-13).
#
# Motivo: Docker no reaplica `restart: unless-stopped` a un contenedor que quedó en estado
# `exited` durante un apagado sucio. En el reinicio del 2026-09-08 Gjallarhorn salió con código
# 255 mientras el demonio restauraba los contenedores y ya no volvió a arrancar: el sistema de
# alertas quedó caído sin que nada lo notificara. `compose up -d` converge el proyecto entero
# sea cual sea el estado en que quedó cada contenedor.
#
# Usa el Compose base (no el de CD): los servicios de un solo uso `sync-host` y `sync-net`
# necesitan red hacia GitHub y no deben ejecutarse en el arranque.
set -euo pipefail

DIR=${YGG_DIR:-/srv/apps/yggdrasil}
ESTADO=${YGG_ESTADO:-/var/lib/cd-receiver/yggdrasil.json}

# La etiqueta desplegada la guarda el receptor; sin ella, Compose usaría `local` y no encontraría
# las imágenes propias.
TAG=$(jq -r '.current_tag // empty' "$ESTADO" 2>/dev/null || true)
[ -n "$TAG" ] || TAG=local

# El demonio puede tardar en aceptar peticiones aunque systemd ya lo dé por activo.
for _ in $(seq 1 30); do
  docker info >/dev/null 2>&1 && break
  sleep 2
done

cd "$DIR/deploy"
echo "yggdrasil-arranque: convergiendo el stack con IMAGE_TAG=$TAG"
IMAGE_TAG="$TAG" docker compose -f docker-compose.yml -p yggdrasil up -d --no-build
docker compose -f docker-compose.yml -p yggdrasil ps --format '{{.Name}} {{.State}}'
