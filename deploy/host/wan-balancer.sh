#!/usr/bin/env bash
# /usr/local/sbin/wan-balancer.sh
# Balanceo dual-WAN con failover automático.
# - Mantiene tablas de policy routing (respuestas salen por donde entraron)
# - Mantiene la ruta default multipath según salud de cada WAN
# - Hysteresis: FAIL_N fallos seguidos = caída, OK_N éxitos seguidos = retorno

set -u

WAN1_IF="wan1"; WAN1_GW="192.168.1.1"; WAN1_TABLE="wan1"; WAN1_W=1
WAN2_IF="wan2"; WAN2_GW="192.168.2.1"; WAN2_TABLE="wan2"; WAN2_W=1

# Clientes anclados: IPs de LAN que siempre salen por una WAN concreta.
# (La MAC se fija a su IP con dhcp-host en dnsmasq; aqui se enruta la IP.)
PIN_WAN2_IPS=("192.168.10.21")   # 00:00:C0:39:5D:B3
PIN_WAN1_IPS=()
PIN_STRICT=0   # 0: si la WAN anclada cae, el cliente vuelve al balanceo general
               # 1: si la WAN anclada cae, el cliente queda sin salida

CHECK_IP1="1.1.1.1"      # objetivo de salud para wan1
CHECK_IP2="1.0.0.1"      # objetivo de salud para wan2
INTERVAL=5               # segundos entre chequeos
FAIL_N=3                 # fallos consecutivos para marcar caída
OK_N=3                   # éxitos consecutivos para restaurar

fail1=0; ok1=0; up1=-1   # -1 = estado desconocido, fuerza primera aplicación
fail2=0; ok2=0; up2=-1

log() { logger -t wan-balancer "$*"; }

wan_ip() { ip -4 -o addr show dev "$1" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1; }

setup_tables() {
    local ip1 ip2
    ip1=$(wan_ip "$WAN1_IF"); ip2=$(wan_ip "$WAN2_IF")

    # Respuestas de conexiones entrantes: enrutar segun marca de connmark
    # (la marca la pone nftables en mangle_pre segun la WAN de entrada)
    ip rule add fwmark 1 table "$WAN1_TABLE" priority 95 2>/dev/null
    ip rule add fwmark 2 table "$WAN2_TABLE" priority 95 2>/dev/null

    if [[ -n "$ip1" ]]; then
        ip route replace default via "$WAN1_GW" dev "$WAN1_IF" table "$WAN1_TABLE"
        ip route replace 192.168.1.0/24 dev "$WAN1_IF" table "$WAN1_TABLE"
        ip route replace 192.168.10.0/24 dev lan table "$WAN1_TABLE"
        ip rule del from "$ip1" table "$WAN1_TABLE" 2>/dev/null
        ip rule add from "$ip1" table "$WAN1_TABLE" priority 100
    fi
    if [[ -n "$ip2" ]]; then
        ip route replace default via "$WAN2_GW" dev "$WAN2_IF" table "$WAN2_TABLE"
        ip route replace 192.168.2.0/24 dev "$WAN2_IF" table "$WAN2_TABLE"
        ip route replace 192.168.10.0/24 dev lan table "$WAN2_TABLE"
        ip rule del from "$ip2" table "$WAN2_TABLE" 2>/dev/null
        ip rule add from "$ip2" table "$WAN2_TABLE" priority 101
    fi
}

wan_gw6() {  # gateway v6 (link-local del ISP, aprendido por RA)
    ip -6 route show default dev "$1" 2>/dev/null | awk '{print $3; exit}'
}

setup_tables_v6() {
    # Simetria de origen IPv6: trafico con origen del prefijo del ISP X
    # debe salir por wanX (anti-spoofing del ISP). Emparejamos cada prefijo
    # global de lan con su WAN comparando los primeros 32 bits (aggregate del ISP).
    local gw6_1 gw6_2 agg1 agg2 pfx agg
    gw6_1=$(wan_gw6 "$WAN1_IF"); gw6_2=$(wan_gw6 "$WAN2_IF")
    agg1=$(ip -6 -o addr show dev "$WAN1_IF" scope global 2>/dev/null | awk '{print $4}' | cut -d: -f1-2 | head -n1)
    agg2=$(ip -6 -o addr show dev "$WAN2_IF" scope global 2>/dev/null | awk '{print $4}' | cut -d: -f1-2 | head -n1)

    [[ -n "$gw6_1" ]] && ip -6 route replace default via "$gw6_1" dev "$WAN1_IF" table "$WAN1_TABLE"
    [[ -n "$gw6_2" ]] && ip -6 route replace default via "$gw6_2" dev "$WAN2_IF" table "$WAN2_TABLE"

    while read -r pfx; do
        [[ -z "$pfx" ]] && continue
        agg=$(echo "$pfx" | cut -d: -f1-2)
        if [[ -n "$agg1" && "$agg" == "$agg1" ]]; then
            ip -6 rule add from "$pfx" table "$WAN1_TABLE" priority 100 2>/dev/null
        elif [[ -n "$agg2" && "$agg" == "$agg2" ]]; then
            ip -6 rule add from "$pfx" table "$WAN2_TABLE" priority 101 2>/dev/null
        fi
    done < <(ip -6 -o addr show dev lan scope global 2>/dev/null | awk '{print $4}' | sed 's|::1/64|::/64|')
}

check() {  # check <iface> <target>
    # Atar a la IP de origen (no a la interfaz): así el lookup de ruta
    # pasa por la regla "from <ip>" -> tabla wanX, que siempre tiene default.
    # Atar a interfaz falla cuando aun no hay default en la tabla main.
    local ip
    ip=$(wan_ip "$1")
    [[ -n "$ip" ]] || return 1
    ping -c1 -W2 -n -I "$ip" "$2" >/dev/null 2>&1
}

apply_default() {  # apply_default <up1> <up2>
    if [[ "$1" == 1 && "$2" == 1 ]]; then
        ip route replace default \
            nexthop via "$WAN1_GW" dev "$WAN1_IF" weight "$WAN1_W" \
            nexthop via "$WAN2_GW" dev "$WAN2_IF" weight "$WAN2_W"
        log "default: multipath wan1+wan2"
    elif [[ "$1" == 1 ]]; then
        ip route replace default via "$WAN1_GW" dev "$WAN1_IF"
        log "default: solo wan1 (wan2 caida)"
    elif [[ "$2" == 1 ]]; then
        ip route replace default via "$WAN2_GW" dev "$WAN2_IF"
        log "default: solo wan2 (wan1 caida)"
    else
        log "ALERTA: ambas WAN caidas, se conserva la ultima ruta"
    fi
    # Purga el cache de rutas para que el nuevo hash aplique ya
    ip route flush cache 2>/dev/null || true
}

# main_default_ok <up1> <up2>
# Â¿La ruta por defecto de `main` es la que corresponde al estado actual?
#
# Hace falta porque check() sondea con `ping -I <ip de la WAN>`, que entra por la regla
# "from <ip> lookup wanN" y nunca toca `main`. Las dos WAN pueden estar perfectas mientras
# `main` esta rota, y como apply_default solo corria al CAMBIAR de estado, con las dos WAN
# sanas el estado se quedaba en "11" y la ruta no se reaplicaba jamas.
#
# Eso paso el 2026-09-12: `main` se quedo sin ruta utilizable de 06:20 a 13:25 UTC (7 h sin
# internet en casa) con las dos WAN sanas, y solo se arreglo al reiniciar el servicio a mano,
# porque al arrancar up1=-1 fuerza la primera aplicacion.
main_default_ok() {
    local ruta
    ruta=$(ip -4 route show default 2>/dev/null)
    [[ -z "$ruta" ]] && return 1
    if [[ "$1" == 1 && "$2" == 1 ]]; then
        [[ "$ruta" == *"dev $WAN1_IF"* && "$ruta" == *"dev $WAN2_IF"* ]]
    elif [[ "$1" == 1 ]]; then
        [[ "$ruta" == *"via $WAN1_GW"* ]]
    elif [[ "$2" == 1 ]]; then
        [[ "$ruta" == *"via $WAN2_GW"* ]]
    else
        # Ambas caidas: apply_default conserva la ultima ruta a proposito, nada que verificar.
        return 0
    fi
}

setup_pins() {  # setup_pins <up1> <up2>
    local ip
    # Anclados a wan2 (prioridad 90: evalua antes que las reglas de simetria)
    for ip in "${PIN_WAN2_IPS[@]}"; do
        if [[ "$2" == 1 || "$PIN_STRICT" == 1 ]]; then
            ip rule add from "$ip" table "$WAN2_TABLE" priority 90 2>/dev/null
        else
            ip rule del from "$ip" table "$WAN2_TABLE" priority 90 2>/dev/null
        fi
    done
    # Anclados a wan1
    for ip in "${PIN_WAN1_IPS[@]}"; do
        if [[ "$1" == 1 || "$PIN_STRICT" == 1 ]]; then
            ip rule add from "$ip" table "$WAN1_TABLE" priority 90 2>/dev/null
        else
            ip rule del from "$ip" table "$WAN1_TABLE" priority 90 2>/dev/null
        fi
    done
}

log "iniciando wan-balancer"
setup_tables
last_state=""

while true; do
    # Refresca reglas por si DHCP renovó con otra IP
    setup_tables
    setup_tables_v6

    if check "$WAN1_IF" "$CHECK_IP1"; then
        ok1=$((ok1+1)); fail1=0
    else
        fail1=$((fail1+1)); ok1=0
    fi
    if check "$WAN2_IF" "$CHECK_IP2"; then
        ok2=$((ok2+1)); fail2=0
    else
        fail2=$((fail2+1)); ok2=0
    fi

    new1=$up1; new2=$up2
    [[ $fail1 -ge $FAIL_N ]] && new1=0
    [[ $ok1   -ge $OK_N   ]] && new1=1
    [[ $fail2 -ge $FAIL_N ]] && new2=0
    [[ $ok2   -ge $OK_N   ]] && new2=1
    # Primer arranque: aplica lo que responda al primer chequeo
    [[ $up1 -eq -1 ]] && new1=$(( ok1 > 0 ? 1 : 0 ))
    [[ $up2 -eq -1 ]] && new2=$(( ok2 > 0 ? 1 : 0 ))

    state="${new1}${new2}"
    if [[ "$state" != "$last_state" ]]; then
        up1=$new1; up2=$new2
        apply_default "$up1" "$up2"
        last_state="$state"
    elif ! main_default_ok "$new1" "$new2"; then
        # El estado no cambio, pero `main` no tiene la ruta que deberia: la borro un flush,
        # una renovacion de DHCP u otro proceso. `ip route replace` es idempotente, asi que
        # reaplicar es seguro; solo se registra cuando de verdad hubo que reparar algo, para
        # no llenar el journal en el caso normal.
        log "main sin la ruta esperada para el estado $state; reaplicando"
        apply_default "$new1" "$new2"
    fi
    setup_pins "$new1" "$new2"

    sleep "$INTERVAL"
done
