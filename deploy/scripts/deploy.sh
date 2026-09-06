#!/usr/bin/env bash
# Despliegue idempotente en el appliance (ADR-0002): trae main, renderiza, construye Sleipnir y
# levanta el Compose. Sin pipeline push hacia la red doméstica; GitHub Actions solo valida.
set -euo pipefail
cd "$(dirname "$0")/.."

git -C .. pull --ff-only
./scripts/render.sh
docker compose pull --quiet
docker compose build --quiet sleipnir
docker compose up -d --remove-orphans
docker compose ps
