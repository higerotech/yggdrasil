#!/usr/bin/env bash
# Renderiza las plantillas *.tmpl de deploy/ con los valores de .env y las IPv4 actuales de
# las interfaces WAN. Idempotente: se puede ejecutar en cada despliegue o desde un hook DHCP
# cuando el ISP cambie la IP. Con --sin-recarga no toca los contenedores (CI).
set -euo pipefail
cd "$(dirname "$0")/.."

RECARGA=1
[ "${1:-}" = "--sin-recarga" ] && RECARGA=0

[ -f .env ] || { echo "Falta deploy/.env (cp .env.example .env && chmod 600 .env)"; exit 1; }
set -a; . ./.env; set +a

ip_de() { ip -4 -o addr show dev "$1" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1; }
# Última IP renderizada para una WAN (del blackbox.yml anterior), para no fallar el despliegue
# cuando ese ISP está caído: la sonda seguirá fallando por la IP antigua, que es lo correcto.
ip_anterior() { [ -f blackbox/blackbox.yml ] && awk -v m="icmp_$1:" '$1==m{f=1} f&&/source_ip_address/{gsub(/"/,"",$2); print $2; exit}' blackbox/blackbox.yml; }
resolver_wan() { # $1 wan1|wan2  $2 interfaz  $3 valor forzado (.env)
  local ip="$3"
  [ -n "$ip" ] || ip=$(ip_de "$2" || true)
  if [ -z "$ip" ]; then
    ip=$(ip_anterior "$1" || true)
    [ -n "$ip" ] && echo "AVISO: $2 sin IPv4 ahora; se conserva la última conocida ($ip)" >&2
  fi
  [ -n "$ip" ] || { echo "Sin IPv4 en $2 y sin render previo; define ${1^^}_IP en .env o levanta la interfaz" >&2; exit 2; }
  echo "$ip"
}
WAN1_IP=$(resolver_wan wan1 "${WAN1_IF:-wan1}" "${WAN1_IP:-}")
WAN2_IP=$(resolver_wan wan2 "${WAN2_IF:-wan2}" "${WAN2_IP:-}")
export WAN1_IP WAN2_IP

for v in NORNAS_URL NORNAS_WEBHOOK_TOKEN THROUGHPUT_RECEIVER; do
  [ -n "${!v:-}" ] || { echo "Falta $v en .env"; exit 3; }
done

envsubst '${WAN1_IP} ${WAN2_IP}' < blackbox/blackbox.yml.tmpl > blackbox/blackbox.yml
envsubst '${NORNAS_URL} ${NORNAS_WEBHOOK_TOKEN} ${THROUGHPUT_RECEIVER}' \
  < alertmanager/alertmanager.yml.tmpl > alertmanager/alertmanager.yml
# El contenedor (usuario nobody) debe poder leerlo; el directorio deploy/ es la barrera (README).
chmod 0644 blackbox/blackbox.yml alertmanager/alertmanager.yml
echo "Renderizado: wan1=$WAN1_IP wan2=$WAN2_IP throughput→$THROUGHPUT_RECEIVER"

[ "$RECARGA" = 1 ] || exit 0
corriendo() { docker compose ps --status running --services 2>/dev/null | grep -qx "$1"; }
if corriendo huginn-muninn; then
  curl -fsS -X POST "http://${DOCKER_HOST_GW:-172.17.0.1}:9115/-/reload" && echo "blackbox recargado"
fi
if corriendo gjallarhorn; then
  docker compose kill -s HUP gjallarhorn && echo "alertmanager recargado"
fi
