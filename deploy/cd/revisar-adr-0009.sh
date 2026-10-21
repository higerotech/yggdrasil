#!/usr/bin/env bash
# revisar-adr-0009.sh — revision a 30 dias de la ADR-0009 (tunel PIA) con los datos de Mimir.
#
#   revisar-adr-0009.sh            informe por pantalla
#   revisar-adr-0009.sh --aviso    ademas lo guarda en REVISION_DIR y manda un push por ntfy
#
# Lo lanza yggdrasil-revision-adr-0009.timer el 2026-11-20, 30 dias despues de activar la Fase 1
# (2026-10-21). Aplica las «Condiciones de revision» de la ADR:
#   - mas de 30 min en la ventana con perdida >= 1 % por el tunel  -> proponer la Fase 2 (VPS + engarde)
#   - el tunel pierde o tarda mas que la WAN directa que menos pierde -> valorar revertir
#   - menos de REVISION_DIAS_MIN dias de datos                       -> repetir la revision mas tarde
# La decision es de Jeremi: el informe la propone, no cambia nada.
#
# Compara contra 1.1.1.1, el destino que sondea pia-tunel.sh por el tunel y Heimdall por cada WAN.
set -uo pipefail

PROM_URL=${PROM_URL:-}
VENTANA=${REVISION_VENTANA:-30d}
DIAS_MIN=${REVISION_DIAS_MIN:-25}
REVISION_DIR=${REVISION_DIR:-/var/lib/yggdrasil-revisiones}
AVISO_ENV=${AVISO_ENV:-/etc/yggdrasil-aviso.env}
UMBRAL_MIN_PERDIDA=30    # minutos con perdida >= 1 % por el tunel en la ventana
MARGEN_PERDIDA_PP=0.5    # puntos de perdida que el tunel puede llevar de mas sobre la mejor WAN
MARGEN_RTT_MS=30         # ms que el tunel puede tardar de mas sobre la mejor WAN
AVISO=0
[ "${1:-}" = --aviso ] && AVISO=1

if [ -z "$PROM_URL" ]; then
    ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' yggdrasil-prometheus 2>/dev/null | awk '{print $1}')
    PROM_URL="http://${ip:-127.0.0.1}:9090"
fi

valor() {  # valor <promql>: el primer valor del resultado, redondeado a 2 decimales, o vacio
    local r
    r=$(curl -fsS -m 60 -G "$PROM_URL/api/v1/query" --data-urlencode "query=$1" 2>/dev/null) || return 0
    printf '%s' "$r" | jq -r '.data.result[0].value[1] // empty' 2>/dev/null |
        awk '$1 ~ /^[-0-9.e+]+$/ {printf "%.2f", $1}'
}
mayor() { awk -v a="$1" -v b="$2" 'BEGIN {exit !(a + 0 > b + 0)}'; }   # mayor <a> <b>
suma()  { awk -v a="$1" -v b="$2" 'BEGIN {printf "%.2f", a + b}'; }

V=$VENTANA
dias=$(valor "count_over_time(yggdrasil_pia_desvio_activo[$V]) / 1440")
desvio=$(valor "100 * avg_over_time(yggdrasil_pia_desvio_activo[$V])")
perdida=$(valor "100 * increase(yggdrasil_pia_sondas_perdidas_total[$V]) / increase(yggdrasil_pia_sondas_total[$V])")
min_perdida=$(valor "5 * count_over_time(((100 * increase(yggdrasil_pia_sondas_perdidas_total[10m]) / increase(yggdrasil_pia_sondas_total[10m])) >= 1)[$V:5m])")
rtt=$(valor "avg_over_time(yggdrasil_pia_rtt_ms[$V])")
levantamientos=$(valor "increase(yggdrasil_pia_levantamientos_total[$V])")
rechazos=$(valor "increase(yggdrasil_pia_rechazos_total[$V])")
mejor_perdida=""; mejor_rtt=""; mejor_wan=""; directo=""
for w in wan1 wan2; do
    p=$(valor "100 * (1 - avg_over_time(probe_success{job=\"blackbox_icmp_$w\",target=\"1.1.1.1\"}[$V]))")
    r=$(valor "1000 * avg_over_time(probe_icmp_duration_seconds{job=\"blackbox_icmp_$w\",phase=\"rtt\",target=\"1.1.1.1\"}[$V])")
    directo+="  $w directa a 1.1.1.1: perdida ${p:-?} %, RTT medio ${r:-?} ms"$'\n'
    # La referencia es la WAN que menos pierde, la que lleva la casa: una WAN rapida pero degradada
    # (wan2 en octubre de 2026) esta fuera de la ruta y no sirve de comparacion.
    if [ -n "$p" ] && { [ -z "$mejor_perdida" ] || mayor "$mejor_perdida" "$p"; }; then
        mejor_perdida=$p; mejor_rtt=$r; mejor_wan=$w
    fi
done

hallazgos=""; decision=""
if [ -z "$dias" ]; then
    decision="SIN DATOS"
    hallazgos+="- Mimir no responde o no tiene yggdrasil_pia_*: comprobar Thor y pia-tunel.service."$'\n'
else
    if mayor "$DIAS_MIN" "$dias"; then
        decision="DATOS INSUFICIENTES"
        hallazgos+="- Solo hay $dias dias de datos (minimo $DIAS_MIN): repetir la revision cuando haya 30."$'\n'
    fi
    if [ -n "$min_perdida" ] && mayor "$min_perdida" "$UMBRAL_MIN_PERDIDA"; then
        decision=${decision:-"PROPONER FASE 2"}
        hallazgos+="- $min_perdida min con perdida >= 1 % por el tunel (umbral $UMBRAL_MIN_PERDIDA): la Fase 2 (VPS + engarde) duplicaria cada paquete por las dos WAN."$'\n'
    fi
    if [ -n "$perdida" ] && [ -n "$mejor_perdida" ] && mayor "$perdida" "$(suma "$mejor_perdida" "$MARGEN_PERDIDA_PP")"; then
        decision=${decision:-"VALORAR REVERTIR"}
        hallazgos+="- El tunel pierde $perdida %, la mejor WAN directa ($mejor_wan) $mejor_perdida %: PIA empeora la perdida."$'\n'
    fi
    if [ -n "$rtt" ] && [ -n "$mejor_rtt" ] && mayor "$rtt" "$(suma "$mejor_rtt" "$MARGEN_RTT_MS")"; then
        decision=${decision:-"VALORAR REVERTIR"}
        hallazgos+="- El tunel tarda $rtt ms, la WAN de referencia ($mejor_wan) $mejor_rtt ms: probar otra region (PIA_REGION)."$'\n'
    fi
    if [ -n "$rechazos" ] && mayor "$rechazos" 0; then
        hallazgos+="- PIA no dio token o rechazo la clave $rechazos veces: revisar credenciales y la API de PIA."$'\n'
    fi
    if [ -n "$desvio" ] && mayor 99 "$desvio"; then
        horas=$(awk -v d="$desvio" -v n="$dias" 'BEGIN {printf "%.1f", (100 - d) / 100 * n * 24}')
        hallazgos+="- El PC salio directo, sin tunel, ~$horas h ($desvio % del tiempo con desvio)."$'\n'
    fi
    decision=${decision:-"MANTENER FASE 1"}
fi

informe="Revision ADR-0009 (tunel PIA), ventana $V hasta $(date -u +%FT%RZ)
Propuesta: $decision

Tunel: ${dias:-?} dias de datos, desvio activo ${desvio:-?} % del tiempo
  perdida por el tunel ${perdida:-?} %, ${min_perdida:-?} min con perdida >= 1 %, RTT medio ${rtt:-?} ms
  ${levantamientos:-?} levantamientos, ${rechazos:-?} rechazos de PIA
$directo
Hallazgos:
${hallazgos:-- Ninguno: el tunel cumple.
}
Siguiente paso: Jeremi decide; cerrar el issue de la revision con la decision y anotarla en la ADR-0009."

printf '%s\n' "$informe"

if (( AVISO )); then
    mkdir -p "$REVISION_DIR"
    f="$REVISION_DIR/adr-0009-$(date +%F).txt"
    printf '%s\n' "$informe" > "$f"
    chmod 0644 "$f"
    if [ -r "$AVISO_ENV" ]; then
        # El tema de ntfy es la credencial: se carga, nunca se imprime (deploy/cd/README.md)
        # shellcheck disable=SC1090
        . "$AVISO_ENV"
        if [ -n "${AVISO_URL:-}" ]; then
            curl -fsS -m 20 --retry 3 --retry-delay 10 -H "Title: $(hostname -s) - Revision ADR-0009: $decision" \
                -H "Priority: default" -H "Tags: calendar,clipboard" --data-binary @"$f" "$AVISO_URL" >/dev/null \
                && echo "aviso: enviado" || echo "aviso: fallo el push; el informe esta en $f"
        fi
    else
        echo "aviso: no puedo leer $AVISO_ENV; el informe esta en $f"
    fi
fi

[ "$decision" = "SIN DATOS" ] && exit 1
exit 0
