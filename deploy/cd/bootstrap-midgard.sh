#!/usr/bin/env bash
# Prepara el appliance (midgard) para desplegar Yggdrasil con el receptor de despliegue-continuo.
# Idempotente. Ejecutar como root:  sudo bash bootstrap-midgard.sh
# BRANCH (por defecto main): rama a la que apunta el clon inicial. Hasta que los artefactos de CD
# lleguen a main, usar BRANCH=develop para que el receptor encuentre deploy/docker-compose.cd.yml.
# No imprime secretos. Después: crear el webhook en GitHub (deploy/cd/README.md, paso 3).
set -euo pipefail
APP_DIR=${APP_DIR:-/srv/apps/yggdrasil}
REPO=${REPO:-https://github.com/higerotech/yggdrasil.git}
BRANCH=${BRANCH:-main}
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
sudo -u deploy git -C "$APP_DIR" fetch --quiet origin "$BRANCH"
sudo -u deploy git -C "$APP_DIR" checkout --quiet --detach "origin/$BRANCH"
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
  echo "   ya existe; se conservan los valores actuales"
fi
# Completa claves nuevas de .env.example que falten en .env (versiones posteriores del stack);
# los CAMBIAR se sustituyen por valores aleatorios. Nunca modifica claves existentes.
while IFS= read -r linea; do
  clave=${linea%%=*}; valor=${linea#*=}
  grep -q "^${clave}=" "$ENV_FILE" && continue
  if [ "$valor" = CAMBIAR ]; then
    case "$clave" in *_SECRET|*_TOKEN) valor=$(openssl rand -hex 32) ;; *) valor=$(openssl rand -base64 24 | tr -d '/+=') ;; esac
  fi
  printf '%s=%s\n' "$clave" "$valor" >> "$ENV_FILE"; echo "   añadida $clave"
done < <(grep -E '^[A-Z_]+=' "$APP_DIR/deploy/.env.example")
# El webhook de Alertmanager va ahora por la red interna (ADR-0006)
if grep -q '^NORNAS_URL=http://host.docker.internal' "$ENV_FILE"; then
  sed -i 's|^NORNAS_URL=.*|NORNAS_URL=http://nornas:1880/heimdall/alertas|' "$ENV_FILE"; echo "   NORNAS_URL actualizada a la red interna"
fi
echo "   revisar WAN1_IF/WAN2_IF ($(ip -4 -o addr show | awk '{print $2}' | grep -E '^wan' | tr '\n' ' '))"

echo "== 4. Render inicial y validación"
( cd "$APP_DIR/deploy" && sudo -u deploy ./scripts/render.sh --sin-recarga )

echo "== 5. Inventario del receptor ($APPS_YML)"
if ! grep -q 'repo: higerotech/yggdrasil' "$APPS_YML"; then
  sed "s|http://192.0.2.10:3000|http://$LAN_IP:3000|" "$APP_DIR/deploy/cd/apps.yggdrasil.yml" >> "$APPS_YML"
  curl -fsS -X POST http://127.0.0.1:9000/reload >/dev/null && echo "   añadido y receptor recargado"
else
  echo "   ya declarado"
fi

echo "== 5b. Unidad de arranque (converge el stack tras un reinicio)"
install -m 0755 "$APP_DIR/deploy/cd/yggdrasil-arranque.sh" /usr/local/sbin/yggdrasil-arranque.sh
install -m 0644 "$APP_DIR/deploy/cd/yggdrasil-arranque.service" /etc/systemd/system/yggdrasil-arranque.service
systemctl daemon-reload
systemctl enable yggdrasil-arranque.service >/dev/null 2>&1 && echo "   yggdrasil-arranque.service habilitada"

echo "== 6. nftables (proyecto de routing, /etc/nftables.conf): comprobación"
if nft list chain inet router input 2>/dev/null | grep -q 'dport { 9115, 9469 }'; then
  echo "   regla de sondas presente (ip saddr DKR_NET tcp dport { 9115, 9469 } accept)"
else
  cat <<'N'
   FALTA en chain input de la tabla inet router (junto a la regla de DNS para contenedores):
   ip saddr $DKR_NET tcp dport { 9115, 9469 } accept
   Recargar con: nft -c -f /etc/nftables.conf && nft -f /etc/nftables.conf
N
fi
echo "== Listo. Falta el webhook en GitHub (paso 3 de deploy/cd/README.md) y el primer push a main."
