#!/usr/bin/env bash
# yggdrasil-vigia-servicios.sh — avisa por ntfy cuando un servicio de Yggdrasil sale de linea y
# cuando vuelve. Lo lanza yggdrasil-vigia-servicios.timer cada minuto.
#
# Que vigila:
#   - los servicios PERMANENTES del Compose de Yggdrasil (restart distinto de "no"), sacados del
#     propio docker-compose.yml: un servicio nuevo entra solo, y las tareas de un solo uso
#     (nornas-init, sync-*) quedan fuera. Caido = el contenedor no existe, no esta en marcha o
#     su healthcheck dice unhealthy. "paused" cuenta como en marcha (el respaldo congela unos s).
#   - las unidades del host de las que depende el proyecto (VIGIA_UNIDADES). Las que no existan
#     en la maquina se saltan.
#
# Por que en el host y no como alerta de Prometheus: entre los vigilados estan Mimir,
# Gjallarhorn y Nornas, que son la propia cadena de alertas. Si cae uno de ellos, una alerta que
# dependa de esa cadena no la entrega nadie. Va directo a ntfy, como los avisos del respaldo.
#
# Contra el ruido:
#   - VIGIA_UMBRAL comprobaciones seguidas en fallo antes de avisar (2 = unos 2 min);
#   - nada en los primeros VIGIA_GRACIA_S segundos tras arrancar: Odin tarda ~400 s en el HDD;
#   - con docker caido solo se avisa de docker, no de cada contenedor;
#   - un push por pasada con la lista, recordatorio cada VIGIA_RECORDAR_H horas, y otro al volver.
# Si el push falla (p. ej. sin internet), no se marca como avisado y se reintenta en la siguiente.
#
# El tema de ntfy ES la credencial: se lee de AVISO_ENV (en midgard, enlace a smartd-aviso.env).
set -euo pipefail

AVISO_ENV=${AVISO_ENV:-/etc/yggdrasil-aviso.env}
ESTADO=${VIGIA_ESTADO:-/var/lib/yggdrasil-vigia}
COMPOSE=${VIGIA_COMPOSE:-/srv/apps/yggdrasil/deploy/docker-compose.yml}
UNIDADES=${VIGIA_UNIDADES:-docker.service wan-balancer.service dnsmasq.service cd-receiver.service wan-watchdog.timer yggdrasil-respaldo.timer yggdrasil-respaldo-vigia.timer}
UMBRAL=${VIGIA_UMBRAL:-2}
GRACIA_S=${VIGIA_GRACIA_S:-600}
RECORDAR_S=$(( ${VIGIA_RECORDAR_H:-6} * 3600 ))
UPTIME_S=${VIGIA_UPTIME_S:-$(cut -d. -f1 /proc/uptime)}
AHORA=${VIGIA_AHORA:-$(date +%s)}
HOST=$(hostname -s)

if [ "$UPTIME_S" -lt "$GRACIA_S" ]; then
    echo "vigia: arranque reciente (${UPTIME_S} s < ${GRACIA_S} s), no se comprueba"
    exit 0
fi
[ -r "$AVISO_ENV" ] || { echo "vigia: no puedo leer $AVISO_ENV"; exit 1; }
# shellcheck disable=SC1090
. "$AVISO_ENV"
[ -n "${AVISO_URL:-}" ] || { echo "vigia: AVISO_URL vacio en $AVISO_ENV"; exit 1; }
mkdir -p "$ESTADO"

enviar() {   # enviar <titulo> <prioridad> <etiquetas> <mensaje>
    curl -fsS -m 20 --retry 2 --retry-delay 5 \
        -H "Title: $HOST - $1" -H "Priority: $2" -H "Tags: $3" \
        -d "$4" "$AVISO_URL" >/dev/null
}

# --- Inventario --------------------------------------------------------------------------
# El Compose solo lo puede leer root (deploy/ es 750 y lleva .env). Si no se puede, se usa la
# ultima lista buena: un fallo del inventario no debe dejar de vigilar lo que ya se conocia.
contenedores() {
    local lista
    if lista=$(docker compose -f "$COMPOSE" config --format json 2>/dev/null |
               jq -r '.services[] | select((.restart // "no") != "no") | .container_name // empty') &&
       [ -n "$lista" ]; then
        printf '%s\n' "$lista" > "$ESTADO/.inventario"
    elif [ -s "$ESTADO/.inventario" ]; then
        echo "vigia: no pude leer $COMPOSE; uso el inventario anterior" >&2
        lista=$(cat "$ESTADO/.inventario")
    fi
    printf '%s\n' "$lista"
}

# Devuelve vacio si esta bien, o el motivo del fallo.
fallo_contenedor() {
    local s
    s=$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "$1" 2>/dev/null) \
        || { echo "no existe"; return; }
    case "$s" in
        running\ unhealthy|paused\ unhealthy) echo "unhealthy" ;;
        running\ *|paused\ *) ;;
        *) echo "${s%% *}" ;;
    esac
}

fallo_unidad() {
    local s
    s=$(systemctl is-active "$1" 2>/dev/null || true)
    [ "$s" = active ] || echo "${s:-desconocido}"
}

existe_unidad() { [ -n "$(systemctl list-unit-files --no-legend "$1" 2>/dev/null)" ]; }

# --- Comprobacion ------------------------------------------------------------------------
caidos=(); recuerdos=(); recuperados=()
claves_avisadas=()

# registrar <clave> <nombre visible> <motivo o vacio>
registrar() {
    local clave="$1" nombre="$2" motivo="$3" f="$ESTADO/$1" fallos=0 avisado=0
    [ -f "$f" ] && read -r fallos avisado < "$f"
    if [ -z "$motivo" ]; then
        [ "$avisado" -gt 0 ] && recuperados+=("$nombre")
        rm -f "$f"
        return
    fi
    fallos=$((fallos + 1))
    if [ "$fallos" -ge "$UMBRAL" ]; then
        if [ "$avisado" -eq 0 ]; then
            caidos+=("$nombre: $motivo"); claves_avisadas+=("$clave")
        elif [ $((AHORA - avisado)) -ge "$RECORDAR_S" ]; then
            recuerdos+=("$nombre: $motivo"); claves_avisadas+=("$clave")
        fi
    fi
    echo "$fallos $avisado" > "$f"
}

docker_ok=1
for u in $UNIDADES; do
    existe_unidad "$u" || continue
    m=$(fallo_unidad "$u")
    [ "$u" = docker.service ] && [ -n "$m" ] && docker_ok=0
    registrar "u-$u" "$u" "$m"
done

if [ "$docker_ok" = 1 ]; then
    inventario=$(contenedores)
    # Sin Compose legible ni inventario anterior no se vigilaria ningun contenedor, y en silencio:
    # eso es en si un fallo que hay que avisar (visto al probarlo con PrivateTmp en 2026-10-06).
    if [ -z "$inventario" ]; then
        registrar "inventario" "inventario de contenedores" "no puedo leer $COMPOSE"
    else
        registrar "inventario" "inventario de contenedores" ""
        while read -r c; do
            [ -n "$c" ] || continue
            registrar "c-$c" "$c" "$(fallo_contenedor "$c")"
        done <<<"$inventario"
    fi
fi

# --- Avisos ------------------------------------------------------------------------------
marcar_avisados() {
    local k f fallos avisado
    for k in "${claves_avisadas[@]}"; do
        f="$ESTADO/$k"; read -r fallos avisado < "$f"
        echo "$fallos $AHORA" > "$f"
    done
}

lista() { printf -- '- %s\n' "$@"; }

if [ ${#caidos[@]} -gt 0 ] || [ ${#recuerdos[@]} -gt 0 ]; then
    msg=""
    [ ${#caidos[@]} -gt 0 ] && msg+="Fuera de linea:"$'\n'"$(lista "${caidos[@]}")"$'\n'
    [ ${#recuerdos[@]} -gt 0 ] && msg+="Siguen caidos:"$'\n'"$(lista "${recuerdos[@]}")"$'\n'
    titulo="Servicio caido"
    [ $(( ${#caidos[@]} + ${#recuerdos[@]} )) -gt 1 ] && titulo="Servicios caidos"
    if enviar "$titulo" high "rotating_light" "${msg%$'\n'}"; then
        marcar_avisados
        echo "vigia: aviso enviado: ${caidos[*]} ${recuerdos[*]}"
    else
        echo "vigia: no se pudo enviar el aviso; se reintenta en la siguiente pasada"
    fi
fi

if [ ${#recuperados[@]} -gt 0 ]; then
    if enviar "Servicio recuperado" default "white_check_mark" "De vuelta:"$'\n'"$(lista "${recuperados[@]}")"; then
        echo "vigia: recuperados: ${recuperados[*]}"
    else
        echo "vigia: no se pudo enviar el aviso de recuperacion"
    fi
fi
exit 0
