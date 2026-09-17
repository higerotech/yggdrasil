#!/usr/bin/env bash
# /usr/local/sbin/wan-watchdog.sh
#
# Guardian de la ruta real de la casa. Segunda capa, independiente de wan-balancer.
#
# POR QUE EXISTE
# wan-balancer sondea cada WAN con `ping -I <ip de la WAN>`, que entra por la regla
# "from <ip> lookup wanN" y nunca toca la tabla `main`. Eso es correcto para medir la salud
# del ENLACE, pero significa que las dos WAN pueden estar perfectas mientras `main` --por
# donde salen la LAN, dnsmasq y los contenedores-- esta rota.
#
# El 2026-09-12, de 06:20 a 13:25 UTC, `main` se quedo sin ruta utilizable (dockerd:
# "dial udp 1.1.1.1:53: connect: network is unreachable"). La casa estuvo 7 h sin internet,
# Heimdall reporto hogar:up = 1 todo el rato y no se disparo ninguna alerta. Se arreglo a mano
# con `systemctl restart dnsmasq wan-balancer`.
#
# La causa raiz --que apply_default solo corria al cambiar de estado-- esta corregida en
# wan-balancer.sh (ver main_default_ok). Este guardian cubre lo que ese arreglo NO puede:
#   - que la ruta EXISTA y apunte bien pero el trafico no pase igualmente;
#   - que el propio wan-balancer este colgado (systemd lo revive si muere, no si se cuelga);
#   - que dnsmasq deje de resolver, que es un punto unico de fallo compartido por ambas WAN.
#
# QUE HACE
#   1. Comprueba la ruta real: ping SIN -I, o sea por `main`, como sale la casa.
#   2. Comprueba la resolucion por dnsmasq (127.0.0.1).
#   3. Comprueba cada WAN por su tabla, igual que wan-balancer, solo para diagnosticar.
#   4. Si `main` esta rota y al menos una WAN responde -> reinicia wan-balancer y reverifica.
#      Si `main` va pero el DNS no -> reinicia dnsmasq y reverifica.
#      Si ambas WAN estan caidas -> NO toca nada: es un corte aguas arriba y reiniciar solo
#      mete ruido. Lo registra y sale.
#
# GUARDARRAILES
#   - flock: nunca dos ejecuciones a la vez.
#   - Reintentos internos antes de declarar el fallo: un blip no dispara un reinicio.
#   - Cooldown: como mucho MAX_REMEDIOS en VENTANA_REMEDIOS segundos. Si se supera, registra
#     critico y NO actua, para no entrar en un bucle de reinicios.
#   - DRY_RUN=1 o --dry-run: diagnostica y dice que haria, sin tocar nada.
#
# USO
#   wan-watchdog.sh              una pasada (lo que ejecuta el timer)
#   wan-watchdog.sh --dry-run    diagnostica sin remediar
#   wan-watchdog.sh --estado     solo el diagnostico, nunca remedia, salida legible
#
# SALIDA
#   0 todo bien, o remediado con exito
#   1 problema detectado y NO resuelto
#   2 corte aguas arriba (ambas WAN caidas): no hay nada que remediar aqui
#   3 hacia falta remediar pero el cooldown lo impidio

set -uo pipefail

# --- Configuracion (debe cuadrar con wan-balancer.sh) -------------------------------------
WAN1_IF="wan1"; WAN2_IF="wan2"
OBJETIVOS_RUTA=("1.1.1.1" "8.8.8.8")   # se prueban por `main`; basta que responda uno
OBJETIVO_WAN1="1.1.1.1"                # mismos que usa wan-balancer para cada enlace
OBJETIVO_WAN2="1.0.0.1"
NOMBRE_DNS="www.gstatic.com"           # el mismo que sondea Heimdall
RESOLUTOR="127.0.0.1"

INTENTOS=3            # sondeos antes de declarar un fallo
ESPERA_INTENTO=4      # segundos entre sondeos
TIMEOUT_PING=2
TIMEOUT_DNS=3
ESPERA_TRAS_REMEDIO=8 # margen para que el servicio reinicie antes de reverificar

MAX_REMEDIOS=3
VENTANA_REMEDIOS=3600 # 3 remedios por hora como maximo

DIR_ESTADO="/var/lib/wan-watchdog"
FICHERO_ESTADO="$DIR_ESTADO/remedios"
DIR_BLOQUEO="/run/wan-watchdog"        # RuntimeDirectory de la unidad; se crea a mano si se lanza suelto
BLOQUEO="$DIR_BLOQUEO/lock"

DRY_RUN="${DRY_RUN:-0}"
SOLO_ESTADO=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --estado)  SOLO_ESTADO=1; DRY_RUN=1 ;;
        -h|--help) sed -n '2,50p' "$0"; exit 0 ;;
        *) echo "opcion desconocida: $arg" >&2; exit 64 ;;
    esac
done

log()  { logger -t wan-watchdog -p "daemon.${2:-info}" -- "$1"; { [[ -t 1 || $SOLO_ESTADO -eq 1 || $DRY_RUN == 1 ]] && echo "$1"; } || true; }
crit() { log "$1" err; }

# --- Sondeos -----------------------------------------------------------------------------

# Por `main`: sin -I, exactamente como sale la casa. Es LA comprobacion que no hace nadie mas.
sondear_ruta() {
    local objetivo
    for objetivo in "${OBJETIVOS_RUTA[@]}"; do
        ping -c1 -W"$TIMEOUT_PING" -n "$objetivo" >/dev/null 2>&1 && return 0
    done
    return 1
}

# Por la tabla de la WAN: atado a su IP de origen, igual que hace wan-balancer.
sondear_wan() {  # sondear_wan <interfaz> <objetivo>
    local ip
    ip=$(ip -4 -o addr show dev "$1" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
    [[ -z "$ip" ]] && return 1
    ping -c1 -W"$TIMEOUT_PING" -n -I "$ip" "$2" >/dev/null 2>&1
}

sondear_dns() {
    local r
    r=$(dig +short +time="$TIMEOUT_DNS" +tries=1 "@$RESOLUTOR" "$NOMBRE_DNS" A 2>/dev/null | head -n1)
    [[ -n "$r" ]]
}

# Repite un sondeo antes de darlo por fallido: un paquete perdido no justifica un reinicio.
confirmar_fallo() {  # confirmar_fallo <funcion> [args...]
    local i
    for ((i = 1; i <= INTENTOS; i++)); do
        if "$@"; then return 1; fi          # respondio: no hay fallo
        [[ $i -lt $INTENTOS ]] && sleep "$ESPERA_INTENTO"
    done
    return 0                                 # fallo confirmado
}

# --- Cooldown ----------------------------------------------------------------------------
# El fichero de estado guarda una marca de tiempo por remedio; se descartan las viejas.

remedios_recientes() {
    local ahora corte n=0 ts
    ahora=$(date +%s); corte=$((ahora - VENTANA_REMEDIOS))
    [[ -f "$FICHERO_ESTADO" ]] || { echo 0; return; }
    while read -r ts; do
        [[ "$ts" =~ ^[0-9]+$ ]] && [[ $ts -ge $corte ]] && n=$((n + 1))
    done < "$FICHERO_ESTADO"
    echo "$n"
}

anotar_remedio() {
    local ahora corte tmp
    ahora=$(date +%s); corte=$((ahora - VENTANA_REMEDIOS))
    mkdir -p "$DIR_ESTADO"
    tmp=$(mktemp "$DIR_ESTADO/.remedios.XXXXXX") || return 0
    { [[ -f "$FICHERO_ESTADO" ]] && awk -v c="$corte" '/^[0-9]+$/ && $1 >= c' "$FICHERO_ESTADO"; echo "$ahora"; } > "$tmp"
    mv -f "$tmp" "$FICHERO_ESTADO"
}

hay_cupo() {
    local n; n=$(remedios_recientes)
    [[ $n -lt $MAX_REMEDIOS ]]
}

# --- Remediacion -------------------------------------------------------------------------

reiniciar() {  # reiniciar <servicio...>
    if [[ "$DRY_RUN" == 1 ]]; then
        log "DRY-RUN: reiniciaria $*"
        return 0
    fi
    anotar_remedio
    log "reiniciando $*" warning
    systemctl restart "$@"
}

# --- Diagnostico -------------------------------------------------------------------------

ruta_ok=1; dns_ok=1; wan1_ok=1; wan2_ok=1
confirmar_fallo sondear_ruta                       && ruta_ok=0
confirmar_fallo sondear_dns                        && dns_ok=0
sondear_wan "$WAN1_IF" "$OBJETIVO_WAN1"            || wan1_ok=0
sondear_wan "$WAN2_IF" "$OBJETIVO_WAN2"            || wan2_ok=0

resumen="ruta_main=$ruta_ok dns=$dns_ok wan1=$wan1_ok wan2=$wan2_ok"

if [[ $SOLO_ESTADO -eq 1 ]]; then
    echo "$resumen"
    echo "ruta por defecto: $(ip -4 route show default | tr '\n' ' ')"
    echo "remedios en la ultima hora: $(remedios_recientes)/$MAX_REMEDIOS"
    [[ $ruta_ok -eq 1 && $dns_ok -eq 1 ]] && exit 0 || exit 1
fi

# Todo bien: ni una linea en el journal, para que cuando aparezca algo signifique algo.
if [[ $ruta_ok -eq 1 && $dns_ok -eq 1 ]]; then
    exit 0
fi

# Solo una instancia a la vez a partir de aqui.
mkdir -p "$DIR_BLOQUEO" 2>/dev/null || true
exec 9>"$BLOQUEO"
flock -n 9 || { log "otra ejecucion en curso, salgo"; exit 0; }

# Ambas WAN caidas: corte real aguas arriba. Reiniciar no arregla nada y ensucia el diagnostico.
if [[ $wan1_ok -eq 0 && $wan2_ok -eq 0 ]]; then
    crit "las dos WAN estan caidas ($resumen): corte aguas arriba, no se remedia"
    exit 2
fi

if ! hay_cupo; then
    crit "problema detectado ($resumen) pero se alcanzo el limite de $MAX_REMEDIOS remedios en $((VENTANA_REMEDIOS / 60)) min; NO se actua. Revisar a mano."
    exit 3
fi

salida=0

# Caso 1: la casa no sale aunque haya al menos una WAN sana. Es el fallo del 2026-09-12.
if [[ $ruta_ok -eq 0 ]]; then
    crit "la casa no sale por main aunque wan1=$wan1_ok wan2=$wan2_ok: reiniciando wan-balancer"
    reiniciar wan-balancer
    [[ "$DRY_RUN" == 1 ]] || sleep "$ESPERA_TRAS_REMEDIO"
    if [[ "$DRY_RUN" == 1 ]]; then
        :
    elif confirmar_fallo sondear_ruta; then
        crit "la ruta sigue rota tras reiniciar wan-balancer. Revisar a mano: ip route get 1.1.1.1; systemctl status wan-balancer"
        salida=1
    else
        log "ruta restablecida tras reiniciar wan-balancer" warning
        ruta_ok=1
        confirmar_fallo sondear_dns && dns_ok=0 || dns_ok=1
    fi
fi

# Caso 2: se sale a internet pero el resolutor no responde. dnsmasq atascado.
if [[ $ruta_ok -eq 1 && $dns_ok -eq 0 ]]; then
    if hay_cupo; then
        crit "la ruta funciona pero dnsmasq no resuelve $NOMBRE_DNS: reiniciando dnsmasq"
        reiniciar dnsmasq
        [[ "$DRY_RUN" == 1 ]] || sleep "$ESPERA_TRAS_REMEDIO"
        if [[ "$DRY_RUN" == 1 ]]; then
            :
        elif confirmar_fallo sondear_dns; then
            crit "dnsmasq sigue sin resolver tras reiniciarlo. Revisar a mano: systemctl status dnsmasq"
            salida=1
        else
            log "resolucion restablecida tras reiniciar dnsmasq" warning
        fi
    else
        crit "dnsmasq no resuelve pero se agoto el cupo de remedios; NO se actua"
        salida=3
    fi
fi

exit "$salida"
