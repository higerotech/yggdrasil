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
#
# 2026-09-17: retirado el anclaje de 192.168.10.21 (MAC 00:00:C0:39:5D:B3, el NAS).
# Llevaba tiempo muerto: esa MAC tiene IP fija 192.168.10.30 en el propio NAS, y el
# pool DHCP empieza en .50, asi que NADIE tenia ni podia tener la .21. La regla
# "from 192.168.10.21 lookup wan2" existia en el kernel sin coincidir con nada, y el
# NAS nunca salio por wan2 como el anclaje pretendia. Decision del owner: ya no aplica.
#
# OJO al editar: setup_pins solo borra las reglas de las IPs que siguen en estos arrays.
# Si quitas una IP de aqui, su regla sobrevive en el kernel hasta el proximo arranque;
# hay que retirarla a mano con `ip rule del from <ip> table <tabla> priority 90`.
PIN_WAN2_IPS=()
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

# podar_reglas_origen <familia: -4|-6> <tabla> <prioridad> [origenes_vigentes...]
#
# Borra las reglas "from X lookup <tabla>" de esa prioridad cuyo X NO este entre los
# origenes vigentes. No anade nada: de eso se encarga quien la llama.
#
# Hace falta porque el borrado puntual de mas abajo (`ip rule del from $ip_actual`) solo
# alcanza a la IP vigente, nunca a las ANTERIORES. Cada renovacion de DHCP con IP distinta
# dejaba una regla huerfana viva para siempre. Observado el 2026-09-17: wan2 paso de
# 192.168.2.8 a .7 al recuperar carrier y quedaron las dos reglas conviviendo. Inofensivo
# mientras nadie tenga la IP vieja, pero si el ISP se la reasigna a otro equipo de esa
# red, su trafico se enrutaria por esa WAN sin motivo.
#
# Solo toca reglas con selector `from <direccion>` en la prioridad indicada, asi que las
# de fwmark (95) y los anclajes de clientes (90) quedan intactas. El filtro $3!="all"
# excluye ademas las reglas "from all ..." por si alguna compartiera prioridad.
podar_reglas_origen() {
    local fam="$1" tabla="$2" prio="$3"; shift 3
    local origen v conservar
    while read -r origen; do
        [[ -z "$origen" ]] && continue
        conservar=0
        for v in "$@"; do [[ "$origen" == "$v" ]] && { conservar=1; break; }; done
        [[ $conservar -eq 0 ]] && ip "$fam" rule del from "$origen" table "$tabla" priority "$prio" 2>/dev/null
    done < <(ip "$fam" rule show 2>/dev/null |
             awk -v p="${prio}:" -v t="$tabla" '$1==p && $2=="from" && $3!="all" && $NF==t {print $3}')
    return 0
}

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
        podar_reglas_origen -4 "$WAN1_TABLE" 100 "$ip1"
        ip rule del from "$ip1" table "$WAN1_TABLE" 2>/dev/null
        ip rule add from "$ip1" table "$WAN1_TABLE" priority 100
    fi
    if [[ -n "$ip2" ]]; then
        ip route replace default via "$WAN2_GW" dev "$WAN2_IF" table "$WAN2_TABLE"
        ip route replace 192.168.2.0/24 dev "$WAN2_IF" table "$WAN2_TABLE"
        ip route replace 192.168.10.0/24 dev lan table "$WAN2_TABLE"
        podar_reglas_origen -4 "$WAN2_TABLE" 101 "$ip2"
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
    local -a pfx_actuales
    gw6_1=$(wan_gw6 "$WAN1_IF"); gw6_2=$(wan_gw6 "$WAN2_IF")
    agg1=$(ip -6 -o addr show dev "$WAN1_IF" scope global 2>/dev/null | awk '{print $4}' | cut -d: -f1-2 | head -n1)
    agg2=$(ip -6 -o addr show dev "$WAN2_IF" scope global 2>/dev/null | awk '{print $4}' | cut -d: -f1-2 | head -n1)

    [[ -n "$gw6_1" ]] && ip -6 route replace default via "$gw6_1" dev "$WAN1_IF" table "$WAN1_TABLE"
    [[ -n "$gw6_2" ]] && ip -6 route replace default via "$gw6_2" dev "$WAN2_IF" table "$WAN2_TABLE"

    # Prefijos globales que lan tiene AHORA. Se calculan una vez para poder podar antes
    # de reanadir: el prefijo delegado por el ISP cambia cada vez que renueva.
    mapfile -t pfx_actuales < <(ip -6 -o addr show dev lan scope global 2>/dev/null |
                                awk '{print $4}' | sed 's|::1/64|::/64|')

    # Barre los prefijos que ya no estan en lan. Sin esto, cada renovacion con prefijo
    # nuevo dejaba la regla del anterior viva para siempre, igual que en IPv4.
    podar_reglas_origen -6 "$WAN1_TABLE" 100 "${pfx_actuales[@]}"
    podar_reglas_origen -6 "$WAN2_TABLE" 101 "${pfx_actuales[@]}"

    for pfx in "${pfx_actuales[@]}"; do
        [[ -z "$pfx" ]] && continue
        agg=$(echo "$pfx" | cut -d: -f1-2)
        # El `del` previo NO sobra: `ip rule add` admite duplicados, asi que sin el se
        # acumulaba una regla identica por cada vuelta del bucle (cada 5 s).
        if [[ -n "$agg1" && "$agg" == "$agg1" ]]; then
            ip -6 rule del from "$pfx" table "$WAN1_TABLE" priority 100 2>/dev/null
            ip -6 rule add from "$pfx" table "$WAN1_TABLE" priority 100 2>/dev/null
        elif [[ -n "$agg2" && "$agg" == "$agg2" ]]; then
            ip -6 rule del from "$pfx" table "$WAN2_TABLE" priority 101 2>/dev/null
            ip -6 rule add from "$pfx" table "$WAN2_TABLE" priority 101 2>/dev/null
        fi
    done
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
