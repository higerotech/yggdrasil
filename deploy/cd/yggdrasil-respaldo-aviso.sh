#!/usr/bin/env bash
# yggdrasil-respaldo-aviso.sh — avisos por ntfy del respaldo nocturno.
#
#   fallo    lo lanza yggdrasil-respaldo-fallo.service (OnFailure= del respaldo): push inmediato.
#   vigilar  lo lanza yggdrasil-respaldo-vigia.timer cada mañana: push si el ultimo exito tiene
#            mas de RESPALDO_MAX_HORAS. Cubre lo que OnFailure no ve: un temporizador que no se
#            dispara, o un respaldo que nunca termina.
#   prueba   manda un push de prueba para comprobar el canal.
#
# Va directo a ntfy desde el host, como smartd-ntfy, y no por Gjallarhorn → Nornas: la salida push
# de Nornas sigue sin conectar, y este aviso no debe depender del stack que respalda.
#
# El tema de ntfy ES la credencial: quien lo conozca lee los avisos. Vive en AVISO_ENV (root, 600),
# que en midgard es un enlace a /etc/smartd-aviso.env para que haya una sola copia que rotar.
set -euo pipefail

AVISO_ENV=${AVISO_ENV:-/etc/yggdrasil-aviso.env}
ESTADO=${RESPALDO_ESTADO:-/var/lib/yggdrasil-respaldo}
MAX_HORAS=${RESPALDO_MAX_HORAS:-26}
HOST=$(hostname -s)

[ -r "$AVISO_ENV" ] || { echo "aviso: no puedo leer $AVISO_ENV"; exit 1; }
# shellcheck disable=SC1090
. "$AVISO_ENV"
[ -n "${AVISO_URL:-}" ] || { echo "aviso: AVISO_URL vacio en $AVISO_ENV"; exit 1; }

enviar() {   # enviar <titulo> <prioridad> <etiquetas> <mensaje>
    curl -fsS -m 20 --retry 3 --retry-delay 10 --retry-all-errors \
        -H "Title: $HOST - $1" -H "Priority: $2" -H "Tags: $3" \
        -d "$4" "$AVISO_URL" >/dev/null
    echo "aviso: enviado ($1)"
}

case "${1:-}" in
    fallo)
        # Las ultimas lineas del propio respaldo: no llevan secretos, solo rutas y tamaños.
        detalle=$(journalctl -u yggdrasil-respaldo.service -n 4 --no-pager -o cat 2>/dev/null | tail -n 4 || true)
        enviar "Respaldo Yggdrasil FALLO" high "warning,floppy_disk" \
            "El respaldo nocturno al NAS ha fallado. journalctl -u yggdrasil-respaldo
$detalle"
        ;;
    vigilar)
        ahora=$(date -u +%s)
        if [ -r "$ESTADO/ultimo-exito" ]; then
            ultimo=$(cat "$ESTADO/ultimo-exito")
            horas=$(( (ahora - ultimo) / 3600 ))
        else
            horas=-1
        fi
        if [ "$horas" -ge 0 ] && [ "$horas" -lt "$MAX_HORAS" ]; then
            echo "aviso: ultimo respaldo hace $horas h, en plazo"
            exit 0
        fi
        if [ "$horas" -lt 0 ]; then
            msg="No consta ningun respaldo completado ($ESTADO/ultimo-exito no existe)."
        else
            msg="El ultimo respaldo completado fue hace $horas h (limite $MAX_HORAS h)."
        fi
        enviar "Respaldo Yggdrasil atrasado" high "warning,floppy_disk" \
            "$msg systemctl list-timers yggdrasil-respaldo.timer"
        ;;
    prueba)
        enviar "Prueba de aviso" default "white_check_mark" \
            "Canal de avisos del respaldo de Yggdrasil operativo."
        ;;
    *)
        echo "uso: $0 fallo|vigilar|prueba"; exit 2 ;;
esac
