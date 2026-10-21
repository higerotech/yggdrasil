#!/usr/bin/env bash
# deploy/host/install-host.sh
# Instala el codigo de host del router de midgard. Idempotente: se puede repetir sin efectos.
#
#   sudo bash deploy/host/install-host.sh              todo
#   sudo bash deploy/host/install-host.sh --solo-guardian   no toca wan-balancer
#   sudo bash deploy/host/install-host.sh --dry-run     dice que haria
#
# wan-balancer se reinicia solo si su contenido cambia. El reinicio es breve y reaplica las
# rutas de inmediato, pero se guarda copia con marca de tiempo antes de tocar nada.

set -euo pipefail

ORIGEN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESTINO_BIN="/usr/local/sbin"
DESTINO_UNIDADES="/etc/systemd/system"

SOLO_GUARDIAN=0
DRY_RUN=0
for arg in "${@:-}"; do
    case "$arg" in
        --solo-guardian) SOLO_GUARDIAN=1 ;;
        --dry-run)       DRY_RUN=1 ;;
        "")              ;;
        *) echo "opcion desconocida: $arg" >&2; exit 64 ;;
    esac
done

[[ $EUID -eq 0 ]] || { echo "hay que ejecutarlo como root" >&2; exit 1; }

ejecutar() {
    if [[ $DRY_RUN == 1 ]]; then echo "  [dry-run] $*"; else "$@"; fi
}

# copiar_si_cambia <origen> <destino> <modo> -> 0 si cambio, 1 si ya estaba igual
copiar_si_cambia() {
    if [[ -f "$2" ]] && cmp -s "$1" "$2"; then
        echo "  sin cambios: $2"
        return 1
    fi
    if [[ -f "$2" ]]; then
        ejecutar cp -a "$2" "$2.bak-$(date +%Y%m%d-%H%M%S)"
        echo "  copia de seguridad de $2"
    fi
    ejecutar install -m "$3" -o root -g root "$1" "$2"
    echo "  instalado: $2"
    return 0
}

echo "== Guardian de la ruta (wan-watchdog) =="
cambio_guardian=0
copiar_si_cambia "$ORIGEN/wan-watchdog.sh"      "$DESTINO_BIN/wan-watchdog.sh"           0755 || true
copiar_si_cambia "$ORIGEN/wan-watchdog.service" "$DESTINO_UNIDADES/wan-watchdog.service" 0644 && cambio_guardian=1 || true
copiar_si_cambia "$ORIGEN/wan-watchdog.timer"   "$DESTINO_UNIDADES/wan-watchdog.timer"   0644 && cambio_guardian=1 || true

if [[ $cambio_guardian == 1 ]]; then
    ejecutar systemctl daemon-reload
fi
ejecutar systemctl enable --now wan-watchdog.timer

echo
if [[ $SOLO_GUARDIAN == 1 ]]; then
    echo "== wan-balancer: omitido (--solo-guardian) =="
else
    echo "== Balanceador (wan-balancer) =="
    if copiar_si_cambia "$ORIGEN/wan-balancer.sh" "$DESTINO_BIN/wan-balancer.sh" 0755; then
        echo "  el contenido cambio: reiniciando wan-balancer"
        ejecutar systemctl restart wan-balancer
    fi
    copiar_si_cambia "$ORIGEN/wan-balancer.service" "$DESTINO_UNIDADES/wan-balancer.service" 0644 \
        && { ejecutar systemctl daemon-reload; ejecutar systemctl restart wan-balancer; } || true
fi

echo
echo "== Tunel PIA (pia-tunel, ADR-0009) =="
cambio_pia=0
ejecutar install -d -m 0755 /usr/local/share/yggdrasil
copiar_si_cambia "$ORIGEN/pia/ca.rsa.4096.crt" /usr/local/share/yggdrasil/pia-ca.rsa.4096.crt 0644 || true
copiar_si_cambia "$ORIGEN/pia-tunel.sh"      "$DESTINO_BIN/pia-tunel.sh"           0755 && cambio_pia=1 || true
copiar_si_cambia "$ORIGEN/pia-tunel.service" "$DESTINO_UNIDADES/pia-tunel.service" 0644 && cambio_pia=1 || true
[[ $cambio_pia == 1 ]] && ejecutar systemctl daemon-reload
if [[ -f /etc/yggdrasil-pia.env ]]; then
    ejecutar systemctl enable pia-tunel.service
    if [[ $cambio_pia == 1 ]] || ! systemctl is-active --quiet pia-tunel.service; then
        echo "  arrancando pia-tunel"
        ejecutar systemctl restart pia-tunel.service
    fi
else
    # Las credenciales las escribe Jeremi: este script nunca las ve (deploy/host/README.md)
    echo "  sin /etc/yggdrasil-pia.env: pia-tunel instalado pero sin arrancar"
fi

echo
echo "== Comprobacion =="
if [[ $DRY_RUN == 1 ]]; then
    echo "  [dry-run] no se comprueba nada"
else
    systemctl is-active wan-balancer >/dev/null && echo "  wan-balancer: activo" || echo "  wan-balancer: NO ACTIVO"
    systemctl is-active wan-watchdog.timer >/dev/null && echo "  wan-watchdog.timer: activo" || echo "  wan-watchdog.timer: NO ACTIVO"
    if [[ -f /etc/yggdrasil-pia.env ]]; then
        systemctl is-active pia-tunel >/dev/null && echo "  pia-tunel: activo" || echo "  pia-tunel: NO ACTIVO"
    fi
    echo
    "$DESTINO_BIN/wan-watchdog.sh" --estado || true
fi
