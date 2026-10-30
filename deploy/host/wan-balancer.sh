#!/usr/bin/env bash
# /usr/local/sbin/wan-balancer.sh
# Balanceo dual-WAN con failover automático.
# - Mantiene tablas de policy routing (respuestas salen por donde entraron)
# - Mantiene la ruta default multipath según salud de cada WAN
# - Hysteresis: FAIL_N fallos TCP seguidos o PERDIDA_SALIDA ping perdidos en la ventana = fuera;
#   OK_N éxitos TCP seguidos y la ventana limpia = retorno
# - Con las dos WAN fuera, la ruta va por la menos mala (menos_mala)

set -u

# Pesos del multipath en proporción al plan contratado (2026-10-30): Servitel en wan1 vende
# 1000/1000 y NetUno en wan2 400/400, así que 5:2. Con 1:1 la mitad de las conexiones iban al
# enlace de 400. El reparto es por conexión (fib_multipath_hash_policy=1), no por byte: una
# descarga sola va entera por la WAN que le toque. Un cambio aquí exige reiniciar el servicio:
# con el estado "11" estable, apply_default no vuelve a correr.
WAN1_IF="wan1"; WAN1_GW="192.168.1.1"; WAN1_TABLE="wan1"; WAN1_W=5
WAN2_IF="wan2"; WAN2_GW="192.168.2.1"; WAN2_TABLE="wan2"; WAN2_W=2

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

# Salud de cada WAN = MAYORIA de tres comprobaciones HTTPS reales, los MISMOS destinos que
# Heimdall (wan:up: 2 de 3 sondas TCP+TLS), para que balanceador y monitor no discrepen.
# Historia (2026-10-06): hasta entonces era un unico ping por WAN (1.1.1.1 / 1.0.0.1). Ese dia
# el ISP2 dejo de llegar a 1.0.0.1 y wan2 salio entera del multipath mientras Heimdall la veia
# sana; ademas tenia un agujero negro de MTU y TCP roto hacia parte de internet mientras los
# ping (paquetes pequenos) pasaban. Decision del owner: mayoria, pero de destinos TCP, que es lo
# que usa la casa. Una WAN con ping y sin TCP queda fuera.
CHECK_ICMP=()
CHECK_TLS=("https://www.gstatic.com/generate_204" "https://1.1.1.1/cdn-cgi/trace" "https://8.8.8.8/")
CHECK_TIMEOUT=3          # segundos por destino (se sondean en paralelo)
INTERVAL=5               # segundos entre chequeos
FAIL_N=2                 # chequeos TCP seguidos sin mayoría para sacar la WAN (era 3 hasta 2026-10-21)
OK_N=6                   # chequeos TCP seguidos con mayoría para devolverla (30 s; eran 3)

# Calidad = pérdida de paquetes (2026-10-21). La mayoría TCP dice si la WAN está viva, no si
# sirve: TCP retransmite y una comprobación HTTPS pasa en 3 s con mucha pérdida. Del 19 al 21 de
# octubre wan2 perdió un 15-30 % de los ping con solo un 2 % de comprobaciones TLS fallidas; nunca
# sumaba 3 fallos seguidos, se quedó en el multipath y le tocaba la mitad de los flujos de la casa
# (una llamada de Slack, entre ellos). Ahora cada chequeo manda además un ping a cada objetivo ICMP
# de Heimdall y la WAN sale si pierde demasiados en la ventana.
#
# Se cuentan los perdidos de los DOS MEJORES objetivos: así uno solo que no conteste (Google descarta
# ping a 8.8.8.8 a ratos) no saca la WAN, igual que la mediana de wan:perdida_pct:5m. La pérdida del
# enlace la ven todos los objetivos.
#
# Umbrales calibrados con 7 días de sondas ICMP de Heimdall (una cada 5 s por objetivo, el mismo
# ritmo que este bucle), ventanas de 24 chequeos y 48 ping de los dos mejores objetivos:
#   wan1 (sana):      ≤ 1 perdido en el 99,77 % de las ventanas; ≥ 3 en el 0,18 %, cortes reales incluidos
#   wan2 (21-oct):    mediana 8 perdidos, p10 5, mínimo 2 en las últimas 6 h
PERDIDA_ICMP=("1.1.1.1" "8.8.8.8" "208.67.222.222")   # los objetivos ICMP de Heimdall
PERDIDA_TIMEOUT=2        # segundos de espera de cada ping
VENTANA=24               # chequeos en la ventana de pérdida (2 min a INTERVAL=5)
PERDIDA_SALIDA=3         # perdidos en la ventana (de 48) para sacar la WAN: ~6 %
PERDIDA_RETORNO=1        # como mucho estos perdidos, con la ventana llena, para devolverla
MARGEN_MENOS_MALA=2      # con las dos fuera, cambiar de WAN solo si la otra pierde 2 ping menos

fail1=0; ok1=0; up1=-1   # -1 = estado desconocido, fuerza primera aplicación
fail2=0; ok2=0; up2=-1
declare -A ventana=()    # "<iface>|<objetivo>" -> últimos VENTANA resultados (1 = perdido)
last_state=""            # ruta aplicada ("11", "10", "01" o "00")
preferida=""             # WAN que lleva la ruta mientras las dos están fuera

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

declare -A ultima_falla=()   # por interfaz: destinos que fallaban en el chequeo anterior

check() {  # check <iface>: 0 si responde la MAYORIA de los destinos de salud
    # Atar a la IP de origen (no a la interfaz): así el lookup de ruta
    # pasa por la regla "from <ip>" -> tabla wanX, que siempre tiene default.
    # Atar a interfaz falla cuando aun no hay default en la tabla main.
    # Ademas apunta en la ventana de perdida un ping a cada objetivo de PERDIDA_ICMP.
    local ip d i r ok=0 mayoria=0 falla=""
    local -a destinos=() pids=() pids_perdida=()
    ip=$(wan_ip "$1")
    [[ -n "$ip" ]] || return 1
    # En paralelo: con destinos caidos, en serie el bucle de INTERVAL s se alargaria
    for d in "${CHECK_ICMP[@]}"; do
        ping -c1 -W"$CHECK_TIMEOUT" -n -I "$ip" "$d" >/dev/null 2>&1 & pids+=($!); destinos+=("$d")
    done
    for d in "${CHECK_TLS[@]}"; do
        curl -fsS -o /dev/null -m "$CHECK_TIMEOUT" --interface "$ip" "$d" >/dev/null 2>&1 & pids+=($!); destinos+=("$d")
    done
    for d in "${PERDIDA_ICMP[@]}"; do
        ping -c1 -W"$PERDIDA_TIMEOUT" -n -I "$ip" "$d" >/dev/null 2>&1 & pids_perdida+=($!)
    done
    for i in "${!pids[@]}"; do
        if wait "${pids[$i]}"; then ok=$((ok + 1)); else falla+="${destinos[$i]} "; fi
    done
    (( ok * 2 > ${#destinos[@]} )) && mayoria=1
    # Los ping solo cuentan si TCP tiene mayoria. Un corte ya lo detecta FAIL_N, y con sus ping en
    # la ventana una WAN que vuelve de un corte de segundos se quedaria fuera 2 min mas. La ventana
    # mide la calidad de una WAN que funciona.
    for i in "${!pids_perdida[@]}"; do
        if wait "${pids_perdida[$i]}"; then r=0; else r=1; fi
        (( mayoria )) && registrar_ping "$1" "${PERDIDA_ICMP[$i]}" "$r"
    done
    # Solo se registra cuando cambia el conjunto de destinos que fallan: un fallo parcial del
    # ISP queda en el journal aunque la WAN siga dentro del multipath.
    if [[ "$falla" != "${ultima_falla[$1]:-}" ]]; then
        if [[ -n "$falla" ]]; then
            log "$1: responden $ok/${#destinos[@]} destinos; fallan: ${falla% }"
        else
            log "$1: responden todos los destinos de salud"
        fi
        ultima_falla[$1]="$falla"
    fi
    (( mayoria ))
}

registrar_ping() {  # registrar_ping <iface> <objetivo> <1 si se perdio, 0 si no>
    local k="$1|$2" s
    s="${ventana[$k]:-}$3"
    # ${s: -N} da vacio si s es mas corta que N: recortar solo cuando sobra
    (( ${#s} > VENTANA )) && s="${s:${#s}-VENTANA}"
    ventana[$k]="$s"
}

perdidos() {  # perdidos <iface>: ping perdidos en la ventana de los dos mejores objetivos
    local d s unos a=999999 b=999999 n
    for d in "${PERDIDA_ICMP[@]}"; do
        s="${ventana[$1|$d]:-}"; unos="${s//0/}"; n=${#unos}
        if (( n < a )); then b=$a; a=$n; elif (( n < b )); then b=$n; fi
    done
    (( b == 999999 )) && b=0
    echo $((a + b))
}

ventana_llena() {  # ventana_llena <iface>: 0 si todos los objetivos tienen VENTANA resultados
    local d s
    for d in "${PERDIDA_ICMP[@]}"; do
        s="${ventana[$1|$d]:-}"
        (( ${#s} >= VENTANA )) || return 1
    done
}

# estado_wan <up actual> <fallos TCP seguidos> <exitos TCP seguidos> <perdidos> <ventana llena 0|1>
# Imprime el estado nuevo: 0 fuera, 1 dentro, o el actual si no hay motivo para cambiar.
estado_wan() {
    if (( $2 >= FAIL_N || $4 >= PERDIDA_SALIDA )); then
        echo 0
    elif (( $3 >= OK_N && $4 <= PERDIDA_RETORNO && $5 == 1 )); then
        echo 1
    else
        echo "$1"
    fi
}

# menos_mala <preferida actual: 1|2|""> <perdidos1> <perdidos2> <tcp1 0|1> <tcp2 0|1>
# Con las dos WAN fuera, cual lleva la ruta. Antes se conservaba la ultima ruta, y cuatro veces
# del 20 al 21 de octubre un corte de segundos en wan1 mando la casa entera por wan2, que perdia un
# 20 %. Ahora gana la que tiene mayoria TCP en el ultimo chequeo; si las dos la tienen, la que pierde
# menos ping, y solo se cambia de la actual si la otra pierde MARGEN_MENOS_MALA menos (evita el
# vaiven). Sin TCP en ninguna es un corte de las dos: se queda la actual. Imprime 1, 2 o "".
menos_mala() {
    local actual="$1" p1="$2" p2="$3" t1="$4" t2="$5"
    if (( t1 != t2 )); then
        (( t1 )) && echo 1 || echo 2
    elif (( ! t1 )); then
        echo "$actual"
    elif [[ "$actual" == 1 ]]; then
        (( p2 + MARGEN_MENOS_MALA <= p1 )) && echo 2 || echo 1
    elif [[ "$actual" == 2 ]]; then
        (( p1 + MARGEN_MENOS_MALA <= p2 )) && echo 1 || echo 2
    else
        (( p2 < p1 )) && echo 2 || echo 1
    fi
}

apply_default() {  # apply_default <up1> <up2> [motivo]
    if [[ "$1" == 1 && "$2" == 1 ]]; then
        ip route replace default \
            nexthop via "$WAN1_GW" dev "$WAN1_IF" weight "$WAN1_W" \
            nexthop via "$WAN2_GW" dev "$WAN2_IF" weight "$WAN2_W"
        log "default: multipath wan1+wan2"
    elif [[ "$1" == 1 ]]; then
        ip route replace default via "$WAN1_GW" dev "$WAN1_IF"
        log "default: solo wan1 (${3:-wan2 fuera})"
    elif [[ "$2" == 1 ]]; then
        ip route replace default via "$WAN2_GW" dev "$WAN2_IF"
        log "default: solo wan2 (${3:-wan1 fuera})"
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

# decidir <tcp1 0|1> <tcp2 0|1>: con el resultado de los chequeos de la vuelta (la mayoria TCP;
# los ping ya estan en la ventana), actualiza contadores, up1/up2 y preferida, y deja la ruta
# efectiva en ruta1/ruta2 y su motivo en `motivo`. Separada del bucle para poder probarla
# (tests/prueba-perdida.sh).
decidir() {
    tcp1=$1; tcp2=$2
    if (( tcp1 )); then ok1=$((ok1+1)); fail1=0; else fail1=$((fail1+1)); ok1=0; fi
    if (( tcp2 )); then ok2=$((ok2+1)); fail2=0; else fail2=$((fail2+1)); ok2=0; fi
    p1=$(perdidos "$WAN1_IF"); ventana_llena "$WAN1_IF" && l1=1 || l1=0
    p2=$(perdidos "$WAN2_IF"); ventana_llena "$WAN2_IF" && l2=1 || l2=0

    new1=$(estado_wan "$up1" "$fail1" "$ok1" "$p1" "$l1")
    new2=$(estado_wan "$up2" "$fail2" "$ok2" "$p2" "$l2")
    # Primer arranque: aplica lo que responda al primer chequeo
    [[ $up1 -eq -1 ]] && new1=$(( ok1 > 0 ? 1 : 0 ))
    [[ $up2 -eq -1 ]] && new2=$(( ok2 > 0 ? 1 : 0 ))
    # El motivo de cada cambio queda en el journal: con la ventana de perdida, "fuera" ya no
    # siempre es "caida"
    [[ $up1 -ne -1 && $new1 -ne $up1 ]] && log "$WAN1_IF: $( ((new1)) && echo dentro || echo fuera) (TCP $ok1 ok/$fail1 fallos seguidos, perdidos $p1/$((2 * VENTANA)) ping en la ventana)"
    [[ $up2 -ne -1 && $new2 -ne $up2 ]] && log "$WAN2_IF: $( ((new2)) && echo dentro || echo fuera) (TCP $ok2 ok/$fail2 fallos seguidos, perdidos $p2/$((2 * VENTANA)) ping en la ventana)"
    up1=$new1; up2=$new2

    # Ruta efectiva: con las dos fuera, la menos mala
    ruta1=$new1; ruta2=$new2; motivo=""
    if [[ $new1 -eq 0 && $new2 -eq 0 ]]; then
        if [[ -z "$preferida" ]]; then
            case "$last_state" in 10) preferida=1 ;; 01) preferida=2 ;; esac
        fi
        preferida=$(menos_mala "$preferida" "$p1" "$p2" "$tcp1" "$tcp2")
        [[ "$preferida" == 1 ]] && ruta1=1
        [[ "$preferida" == 2 ]] && ruta2=1
        motivo="las dos fuera; la menos mala: perdidos wan1 $p1, wan2 $p2"
    else
        preferida=""
    fi
}

# Las pruebas (tests/prueba-quorum.sh y tests/prueba-perdida.sh) cargan las funciones sin entrar
# en el bucle.
[[ "${WAN_BALANCER_SIN_BUCLE:-0}" == 1 ]] && return 0

log "iniciando wan-balancer"
setup_tables

while true; do
    # Refresca reglas por si DHCP renovó con otra IP
    setup_tables
    setup_tables_v6

    check "$WAN1_IF" && t1=1 || t1=0
    check "$WAN2_IF" && t2=1 || t2=0
    decidir "$t1" "$t2"

    state="${ruta1}${ruta2}"
    if [[ "$state" != "$last_state" ]]; then
        apply_default "$ruta1" "$ruta2" "$motivo"
        last_state="$state"
    elif ! main_default_ok "$ruta1" "$ruta2"; then
        # El estado no cambio, pero `main` no tiene la ruta que deberia: la borro un flush,
        # una renovacion de DHCP u otro proceso. `ip route replace` es idempotente, asi que
        # reaplicar es seguro; solo se registra cuando de verdad hubo que reparar algo, para
        # no llenar el journal en el caso normal.
        log "main sin la ruta esperada para el estado $state; reaplicando"
        apply_default "$ruta1" "$ruta2" "$motivo"
    fi
    setup_pins "$ruta1" "$ruta2"

    sleep "$INTERVAL"
done
