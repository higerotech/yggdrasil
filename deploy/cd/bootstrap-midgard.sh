#!/usr/bin/env bash
# Prepara el appliance (midgard) para desplegar Yggdrasil con el receptor de despliegue-continuo.
# Idempotente. Ejecutar como root:  sudo bash bootstrap-midgard.sh
# No imprime secretos. Después: crear el webhook en GitHub (deploy/cd/README.md, paso 3).
set -euo pipefail
APP_DIR=${APP_DIR:-/srv/apps/yggdrasil}
REPO=${REPO:-https://github.com/higerotech/yggdrasil.git}
LAN_IF=${LAN_IF:-lan}
APPS_YML=/etc/cd-receiver/apps.yml
[ "$(id -u)" = 0 ] || { echo "ejecutar con sudo"; exit 1; }
id deploy >/dev/null 2>&1 || { echo "no existe el usuario deploy: instalar despliegue-continuo primero"; exit 1; }

echo "== 1. ICMP sin root para blackbox (net.ipv4.ping_group_range)"
printf 'net.ipv4.ping_group_range = 0 2147483647\n' > /etc/sysctl.d/90-yggdrasil.conf
sysctl -q -p /etc/sysctl.d/90-yggdrasil.conf
echo "   ping_group_range = $(sysctl -n net.ipv4.ping_group_range)"

echo "== 2. Clon del repositorio en $APP_DIR (dueño: deploy)"
if [ ! -d "$APP_DIR/.git" ]; then
  install -d -o deploy -g deploy -m 0750 "$APP_DIR"
  sudo -u deploy git clone --quiet "$REPO" "$APP_DIR"
fi
sudo -u deploy git -C "$APP_DIR" fetch --quiet origin main
sudo -u deploy git -C "$APP_DIR" checkout --quiet --detach origin/main
echo "   $(sudo -u deploy git -C "$APP_DIR" log -1 --format='%h %s')"

echo "== 3. deploy/.env (solo si no existe; nunca se sobrescribe)"
ENV_FILE="$APP_DIR/deploy/.env"
LAN_IP=$(ip -4 -o addr show "$LAN_IF" | awk '{print $4}' | cut -d/ -f1)
if [ ! -f "$ENV_FILE" ]; then
  sudo -u deploy cp "$APP_DIR/deploy/.env.example" "$ENV_FILE"
  chmod 0600 "$ENV_FILE"
  sed -i "s|^HOST_LAN_IP=.*|HOST_LAN_IP=$LAN_IP|" "$ENV_FILE"
  sed -i "s|^DOCKER_HOST_GW=.*|DOCKER_HOST_GW=$(ip -4 -o addr show docker0 | awk '{print $4}' | cut -d/ -f1)|" "$ENV_FILE"
  sed -i "s|^GRAFANA_ADMIN_PASSWORD=.*|GRAFANA_ADMIN_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=')|" "$ENV_FILE"
  sed -i "s|^NORNAS_WEBHOOK_TOKEN=.*|NORNAS_WEBHOOK_TOKEN=$(openssl rand -hex 32)|" "$ENV_FILE"
  printf '\n# uid/gid del usuario deploy, dueño del clon (para las tareas sync del CD)\nDEPLOY_UID=%s\nDEPLOY_GID=%s\n' "$(id -u deploy)" "$(id -g deploy)" >> "$ENV_FILE"
  echo "   creado con contraseña de Grafana y token aleatorios (ver: sudo cat $ENV_FILE)"
else
  echo "   ya existe; sin cambios"
fi
echo "   revisar WAN1_IF/WAN2_IF ($(ip -4 -o addr show | awk '{print $2}' | grep -E '^wan' | tr '\n' ' ')) y NORNAS_URL"

echo "== 4. Render inicial y validación"
( cd "$APP_DIR/deploy" && sudo -u deploy ./scripts/render.sh --sin-recarga )

echo "== 5. Inventario del receptor ($APPS_YML)"
if ! grep -q 'repo: higerotech/yggdrasil' "$APPS_YML"; then
  sed "s|http://192.0.2.10:3000|http://$LAN_IP:3000|" "$APP_DIR/deploy/cd/apps.yggdrasil.yml" >> "$APPS_YML"
  curl -fsS -X POST http://127.0.0.1:9000/reload >/dev/null && echo "   añadido y receptor recargado"
else
  echo "   ya declarado"
fi

echo "== 6. Reglas nftables sugeridas (NO se aplican; añadir a la política del proyecto de routing)"
cat <<'N'
   # sondas de Heimdall en host-mode: solo desde las redes de Docker
   iifname { "docker0", "br-*" } tcp dport { 9115, 9469 } accept
   tcp dport { 9115, 9469 } drop
   # Odín (Grafana) solo desde LAN y WireGuard
   iifname { "lan", "wg0" } tcp dport 3000 accept
N
echo "== Listo. Falta el webhook en GitHub (paso 3 de deploy/cd/README.md) y el primer push a main."
