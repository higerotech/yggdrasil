#!/usr/bin/env bash
# yggdrasil-respaldar.sh — respaldo nocturno de Yggdrasil al NAS.
#
# Que copia: los volumenes de datos del stack (Mimir, Odin, Gjallarhorn, Nornas, Ratatosk,
# Sleipnir), el despliegue /srv/apps/yggdrasil/deploy CON su .env, la etiqueta desplegada y la
# configuracion del router que el stack necesita (nftables, sysctl, netplan, unidades WAN).
# El archivo lleva secretos: directorio 700 y ficheros 600 (el NAS fuerza el propietario, no el modo).
#
# Consistencia: Mimir (TSDB) y Odin (SQLite) se congelan con `docker pause` solo mientras se copian
# a disco local, unos 5 s. Los demas se copian en caliente: Ratatosk y Nornas escriben su estado
# con fichero temporal + rename, y congelarlos marcaria su healthcheck como unhealthy varios
# minutos cada noche.
#
# Lo lanza yggdrasil-respaldo.timer. A mano:  sudo /usr/local/sbin/yggdrasil-respaldar.sh
set -euo pipefail
umask 077

DESTINO=${RESPALDO_DESTINO:-/mnt/nas/respaldos/yggdrasil}
RETENER=${RESPALDO_RETENER:-14}
APP_DIR=${APP_DIR:-/srv/apps/yggdrasil}
ESTADO=${RESPALDO_ESTADO:-/var/lib/yggdrasil-respaldo}
CONGELAR="yggdrasil-prometheus yggdrasil-grafana yggdrasil-alertmanager"
VOLUMENES="mimir-datos odin-datos gjallarhorn-datos nornas-datos ratatosk-datos sleipnir-datos"

[ "$(id -u)" = 0 ] || { echo "ejecutar como root"; exit 1; }

# El trap va antes de crear nada: si el script muere con contenedores congelados, los reanuda.
pausados=""
tmp=""
limpiar() {
    for c in $pausados; do docker unpause "$c" >/dev/null 2>&1 || echo "AVISO: no pude reanudar $c"; done
    if [ -n "$tmp" ]; then rm -rf "$tmp"; fi
}
trap limpiar EXIT

fecha=$(date -u +%Y%m%dT%H%MZ)   # UTC explicito: el host va en UTC y la casa no
nombre="yggdrasil-$fecha.tar.gz"
tmp=$(mktemp -d /var/tmp/yggdrasil-respaldo.XXXXXX)   # disco local, no /tmp en RAM
mkdir -p "$tmp/r/volumenes" "$tmp/r/host"

# Dispara el automount ANTES de congelar: si el NAS no responde, falla aqui sin tocar el stack.
ls "$(dirname "$DESTINO")" >/dev/null

t0=$(date +%s)
for c in $CONGELAR; do docker pause "$c" >/dev/null; pausados="$pausados $c"; done
for v in $VOLUMENES; do
    tar -C "/var/lib/docker/volumes/yggdrasil_$v/_data" --numeric-owner -cpf "$tmp/r/volumenes/$v.tar" .
done
for c in $pausados; do docker unpause "$c" >/dev/null; done
pausados=""
echo "respaldo: Mimir, Odin y Gjallarhorn congelados $(( $(date +%s) - t0 )) s"

tar -C "$APP_DIR" --numeric-owner -cpf "$tmp/r/despliegue.tar" deploy
cp -p /var/lib/cd-receiver/yggdrasil.json "$tmp/r/"
tar -C / --numeric-owner -cpf "$tmp/r/host/host.tar" --ignore-failed-read \
    etc/nftables.conf etc/sysctl.d/90-yggdrasil.conf etc/netplan etc/cd-receiver/apps.yml \
    etc/systemd/system/yggdrasil-arranque.service \
    etc/systemd/system/yggdrasil-respaldo.service etc/systemd/system/yggdrasil-respaldo.timer \
    etc/systemd/system/wan-balancer.service \
    etc/systemd/system/wan-watchdog.service etc/systemd/system/wan-watchdog.timer \
    usr/local/sbin/wan-balancer.sh usr/local/sbin/wan-watchdog.sh \
    usr/local/sbin/yggdrasil-arranque.sh usr/local/sbin/yggdrasil-respaldar.sh
docker ps -a --filter label=com.docker.compose.project=yggdrasil \
    --format '{{.Names}} {{.Image}} {{.Status}}' > "$tmp/r/contenedores.txt"

tar -C "$tmp" -czf "$tmp/$nombre" r
tar -tzf "$tmp/$nombre" >/dev/null
( cd "$tmp" && sha256sum "$nombre" > "$nombre.sha256" )

echo "respaldo: subiendo al NAS ($DESTINO)"
mkdir -p "$DESTINO"
chmod 700 "$DESTINO"
cp "$tmp/$nombre" "$DESTINO/.$nombre.parcial"
cp "$tmp/$nombre.sha256" "$DESTINO/$nombre.sha256"
mv -f "$DESTINO/.$nombre.parcial" "$DESTINO/$nombre"
chmod 600 "$DESTINO/$nombre" "$DESTINO/$nombre.sha256"
( cd "$DESTINO" && sha256sum -c --quiet "$nombre.sha256" ) \
    || { echo "respaldo: la copia en el NAS no coincide con la suma"; exit 1; }

# Retencion: los RETENER mas recientes. Nunca borra si la subida de hoy no esta verificada
# (set -e ya habria salido antes). Ordena por el NOMBRE, que lleva la fecha UTC de midgard, y no
# por mtime: la pone el reloj del NAS, que va desfasado y puede saltar tras un apagon.
archivos=("$DESTINO"/yggdrasil-*.tar.gz)   # el glob sale ordenado: del mas antiguo al mas nuevo
viejos=()
if [ "${#archivos[@]}" -gt "$RETENER" ]; then
    viejos=("${archivos[@]:0:${#archivos[@]}-RETENER}")
fi
for f in "${viejos[@]}"; do rm -f "$f" "$f.sha256"; done

# Marca del ultimo exito, para que una alerta futura detecte un respaldo atrasado.
mkdir -p "$ESTADO"
date -u +%s > "$ESTADO/ultimo-exito"

echo "respaldo: $nombre ($(du -h "$DESTINO/$nombre" | cut -f1)) verificado; ${#viejos[@]} antiguo(s) borrado(s)"
