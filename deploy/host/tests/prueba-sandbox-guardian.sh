#!/usr/bin/env bash
# prueba-sandbox-guardian.sh — ejecuta render.sh DENTRO del sandbox de wan-watchdog.service.
#
# El 2026-10-06 la reconciliacion de sondas fallo en midgard la primera vez que hizo falta:
# la unidad tiene ProtectSystem=strict, /srv era de solo lectura y render.sh no podia escribir
# blackbox.yml. Ninguna prueba lo vio porque el CI ejecuta render.sh fuera de systemd.
#
# Esta prueba lee las directivas de sandbox de la PROPIA unidad, las aplica con systemd-run y
# ejecuta el render como lo hace el guardian. Incluye un control negativo: sin ReadWritePaths
# el render tiene que fallar, o la prueba no estaria probando nada.
#
# Solo para CI (necesita root y systemd, y usa la ruta real /srv/apps/yggdrasil, que no debe
# existir).  Uso:  sudo bash deploy/host/tests/prueba-sandbox-guardian.sh
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../../.." && pwd)
UNIDAD="$REPO/deploy/host/wan-watchdog.service"
RAIZ=/srv/apps/yggdrasil
DESTINO=$RAIZ/deploy
USUARIO=deploy
# IPs de documentacion (RFC 5737): las sondas deben acabar atadas a estas
IP1=192.0.2.101
IP2=198.51.100.102

[ "$(id -u)" = 0 ] || { echo "ejecutar como root"; exit 1; }
[ ! -e "$RAIZ" ] || { echo "$RAIZ ya existe: esta prueba es para CI y no toca un despliegue real"; exit 1; }

# El trap va antes de crear nada
trap 'rm -rf "$RAIZ"' EXIT

id "$USUARIO" >/dev/null 2>&1 || useradd --system --no-create-home "$USUARIO"
mkdir -p "$RAIZ"
cp -a "$REPO/deploy" "$DESTINO"
cp "$DESTINO/.env.example" "$DESTINO/.env"
printf 'WAN1_IP=%s\nWAN2_IP=%s\n' "$IP1" "$IP2" >> "$DESTINO/.env"
chown -R "$USUARIO:" "$RAIZ"
chmod 600 "$DESTINO/.env"

# Directivas de sandbox de la unidad, una por linea, tal cual estan escritas
mapfile -t sandbox < <(grep -E '^(ProtectSystem|ProtectHome|PrivateTmp|NoNewPrivileges|ReadWritePaths|ReadOnlyPaths|InaccessiblePaths)=' "$UNIDAD")
grep -q '^ProtectSystem=' <<<"$(printf '%s\n' "${sandbox[@]}")" \
    || { echo "la unidad ya no declara ProtectSystem: revisar esta prueba"; exit 1; }

render_en_sandbox() {  # render_en_sandbox <directivas...>
    local args=() d
    for d in "$@"; do args+=(-p "$d"); done
    systemd-run --quiet --wait --pipe --collect "${args[@]}" \
        sudo -u "$USUARIO" bash "$DESTINO/scripts/render.sh" --sin-recarga
}

echo "== control negativo: el mismo sandbox SIN ReadWritePaths tiene que fallar"
mapfile -t sin_rw < <(printf '%s\n' "${sandbox[@]}" | grep -v '^ReadWritePaths=')
if render_en_sandbox "${sin_rw[@]}" >/dev/null 2>&1; then
    echo "FALLO: el render funciono sin ReadWritePaths; el sandbox ya no protege /srv y la prueba no prueba nada"
    exit 1
fi
echo "ok: sin ReadWritePaths el render falla"

echo "== render con el sandbox de la unidad"
printf '   %s\n' "${sandbox[@]}"
render_en_sandbox "${sandbox[@]}"

for ip in "$IP1" "$IP2"; do
    grep -q "source_ip_address: \"$ip\"" "$DESTINO/blackbox/blackbox.yml" \
        || { echo "FALLO: blackbox.yml no quedo atado a $ip"; exit 1; }
done
echo "ok: blackbox.yml reescrito con $IP1 y $IP2 dentro del sandbox del guardian"
