#!/usr/bin/env bash
# /usr/local/sbin/pia-tunel.sh
# Tunel WireGuard a Private Internet Access para los equipos de la LAN que lo pidan (ADR-0009).
#
# - Los equipos se eligen por MAC (PIA_MACS en /etc/yggdrasil-pia.conf): todo su IPv4 sale por el
#   tunel, su DNS va al de PIA (sin fuga al ISP) y su IPv6 hacia fuera se descarta (PIA da solo IPv4).
# - Su DNS pasa por un reenviador propio (un dnsmasq aparte en el puerto 5354 de la LAN): los nombres
#   de la casa (casa.lan, sin dominio y la inversa de la LAN) los resuelve el dnsmasq de midgard, y el
#   resto va al DNS de PIA por el tunel. Si el reenviador no arranca, el DNS va directo al de PIA.
# - El tunel lo abre midgard, no el equipo: sus paquetes exteriores salen por la ruta por defecto
#   que mantiene wan-balancer. Si la WAN cambia, WireGuard sigue al nuevo origen y la IP de salida
#   (la de PIA) no cambia: las conexiones del equipo no se cortan.
# - Si el tunel deja de responder, el desvio se retira y los equipos salen directo (R4 de la ADR:
#   disponibilidad antes que privacidad). Vuelve solo cuando el tunel responde otra vez.
#
# Credenciales: /etc/yggdrasil-pia.env (root, 600) con PIA_USER y PIA_PASS. Se leen sin `source`
# (la contrasena puede llevar cualquier caracter) y viajan a curl por descriptores, nunca como
# argumento, que se ve con ps. El token y la clave privada tampoco se escriben en disco ni en el
# journal. Detalle en deploy/host/README.md («Tunel PIA»).

set -u

CONF=${PIA_CONF:-/etc/yggdrasil-pia.conf}               # PIA_REGION, PIA_MACS: sin secretos
CREDENCIALES=${PIA_CREDENCIALES:-/etc/yggdrasil-pia.env} # PIA_USER, PIA_PASS: root 600
CA=${PIA_CA:-/usr/local/share/yggdrasil/pia-ca.rsa.4096.crt}
ESTADO_DIR=${PIA_ESTADO_DIR:-/run/yggdrasil-pia}
LISTA_URL="https://serverlist.piaservers.net/vpninfo/servers/v6"
TOKEN_URL="https://www.privateinternetaccess.com/api/client/v2/token"

IFACE=pia0
LAN_IF=lan
TABLA=300                # tabla de rutas del tunel: solo "default dev pia0"
MARCA=0x10               # marca de los paquetes de los equipos desviados
PRIO_SUPRIMIR=87         # "fwmark lookup main suppress_prefixlength 0": LAN y Docker siguen en local
PRIO_TUNEL=88            # "fwmark lookup 300": todo lo demas, al tunel. Antes que los anclajes (90)
MTU=1380                 # wan2 descarta los paquetes de 1500 B sin avisar (2026-10-06)
SONDA=1.1.1.1            # se sondea a traves del tunel
INTERVAL=5               # segundos entre sondas
FALLOS_N=3               # sondas seguidas sin respuesta para retirar el desvio
REINTENTO_S=60           # espera minima entre intentos de levantar el tunel
TOKEN_VIDA_S=72000       # PIA da tokens de 24 h; se renuevan a las 20
TABLA_NFT=yggdrasil_pia
DNS_PUERTO=5354          # reenviador DNS de los equipos desviados; /etc/nftables.conf lo abre en input
DNS_CASA=127.0.0.1       # dnsmasq de midgard: casa.lan y los nombres del DHCP
DOMINIO=${PIA_DOMINIO:-casa.lan}

token=""; token_desde=0
srv_ip=""; srv_cn=""; srv_region=""; dns_pia=""
tunel=0; desvio=0; fallos=0; ultimo_intento=0; macs_aplicadas=""; dns_aplicado=""
reenviador_pid=""; reenviador_dns=""; reenviador_intento=0
# Contadores para la revision de la ADR-0009 (deploy/cd/revisar-adr-0009.sh), que Thor publica. Las
# sondas solo cuentan con el desvio activo: miden lo que vive el equipo, no un tunel sin usar.
sondas=0; perdidas=0; rtt_ms=0; levantamientos=0; rechazos=0

log() { logger -t pia-tunel "$*"; }

# leer_clave <fichero> <CLAVE>: el valor tal cual, sin interpretarlo como shell
leer_clave() {
    sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n1
}

# macs: las MAC de PIA_MACS validas, en minusculas y separadas por comas (formato de un set de nft)
macs() {
    local m lista=""
    for m in $(leer_clave "$CONF" PIA_MACS | tr 'A-F,' 'a-f '); do
        if [[ "$m" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]]; then
            lista+="${lista:+, }$m"
        else
            log "PIA_MACS: '$m' no es una MAC, se ignora"
        fi
    done
    printf '%s' "$lista"
}

pedir_token() {  # deja el token en `token`; 0 si lo consiguio
    local u p r
    u=$(leer_clave "$CREDENCIALES" PIA_USER); p=$(leer_clave "$CREDENCIALES" PIA_PASS)
    if [[ -z "$u" || -z "$p" ]]; then
        log "faltan PIA_USER o PIA_PASS en $CREDENCIALES"
        return 1
    fi
    # printf es interno de bash: usuario y contrasena llegan a curl por los descriptores 3 y 4
    r=$(curl -s -m 15 -X POST "$TOKEN_URL" -F "username=</dev/fd/3" -F "password=</dev/fd/4" \
            3< <(printf '%s' "$u") 4< <(printf '%s' "$p")) || r=""
    unset u p
    token=$(printf '%s' "$r" | jq -r '.token // empty' 2>/dev/null)
    unset r
    if [[ -z "$token" ]]; then
        log "PIA no dio token: revisar las credenciales de $CREDENCIALES"
        rechazos=$((rechazos + 1))
        return 1
    fi
    token_desde=$(date +%s)
}

elegir_servidor() {  # deja srv_ip, srv_cn y srv_region de la region PIA_REGION
    local lista region
    region=$(leer_clave "$CONF" PIA_REGION); region=${region:-us_florida}
    lista=$(curl -s -m 15 "$LISTA_URL" | head -n1)
    srv_ip=$(printf '%s' "$lista" | jq -r --arg r "$region" '.regions[] | select(.id == $r) | .servers.wg[0].ip // empty' 2>/dev/null)
    srv_cn=$(printf '%s' "$lista" | jq -r --arg r "$region" '.regions[] | select(.id == $r) | .servers.wg[0].cn // empty' 2>/dev/null)
    if [[ -z "$srv_ip" || -z "$srv_cn" ]]; then
        log "la lista de PIA no tiene servidor WireGuard para la region $region"
        return 1
    fi
    srv_region=$region
}

levantar() {  # registra una clave nueva en PIA y monta pia0; 0 si quedo arriba
    local priv pub r clave_srv puerto ip_peer ahora
    ahora=$(date +%s)
    if [[ -z "$token" ]] || (( ahora - token_desde > TOKEN_VIDA_S )); then
        pedir_token || return 1
    fi
    elegir_servidor || return 1
    priv=$(wg genkey); pub=$(printf '%s' "$priv" | wg pubkey)
    r=$(curl -s -m 15 -G --connect-to "$srv_cn::$srv_ip:" --cacert "$CA" \
            --data-urlencode "pt@/dev/fd/3" --data-urlencode "pubkey=$pub" \
            "https://$srv_cn:1337/addKey" 3< <(printf '%s' "$token")) || r=""
    if [[ "$(printf '%s' "$r" | jq -r '.status // empty' 2>/dev/null)" != OK ]]; then
        # Un token caducado o revocado da error aqui: el siguiente intento pide otro
        log "PIA rechazo la clave en $srv_cn ($srv_region)"
        token=""
        rechazos=$((rechazos + 1))
        return 1
    fi
    clave_srv=$(printf '%s' "$r" | jq -r '.server_key'); puerto=$(printf '%s' "$r" | jq -r '.server_port')
    ip_peer=$(printf '%s' "$r" | jq -r '.peer_ip'); dns_pia=$(printf '%s' "$r" | jq -r '.dns_servers[0]')
    unset r

    ip link del "$IFACE" 2>/dev/null
    ip link add "$IFACE" type wireguard || { log "no se pudo crear $IFACE"; return 1; }
    if ! wg set "$IFACE" private-key /dev/fd/3 peer "$clave_srv" endpoint "$srv_ip:$puerto" \
            allowed-ips 0.0.0.0/0 persistent-keepalive 25 3< <(printf '%s' "$priv"); then
        unset priv
        log "no se pudo configurar $IFACE"
        ip link del "$IFACE" 2>/dev/null
        return 1
    fi
    unset priv
    ip addr add "$ip_peer/32" dev "$IFACE"
    ip link set "$IFACE" mtu "$MTU" up
    # Respuestas de internet que entran por pia0: con rp_filter estricto el kernel las tiraria
    sysctl -qw "net.ipv4.conf.$IFACE.rp_filter=2"
    ip route replace default dev "$IFACE" table "$TABLA"
    # El reenviador corre en midgard, sin marca: llega al DNS de PIA por esta ruta de la tabla main
    ip route replace "$dns_pia/32" dev "$IFACE"
    levantamientos=$((levantamientos + 1))
    log "tunel arriba: region $srv_region ($srv_cn), DNS $dns_pia"
}

tunel_responde() {  # 0 si la sonda responde por el tunel; deja su RTT en rtt_ms
    local salida r
    salida=$(ping -c1 -W2 -n -I "$IFACE" "$SONDA" 2>/dev/null) || return 1
    r=$(printf '%s' "$salida" | awk -F'time=' 'NF > 1 {split($2, a, " "); print a[1]; exit}')
    [[ "$r" =~ ^[0-9]+([.][0-9]+)?$ ]] && rtt_ms=$r
    return 0
}

lan_ip() {  # la IPv4 de midgard en la LAN
    ip -4 -o addr show dev "$LAN_IF" | awk '{split($4, a, "/"); print a[1]; exit}'
}

reenviador_vivo() { [[ -n "$reenviador_pid" ]] && kill -0 "$reenviador_pid" 2>/dev/null; }

parar_reenviador() {
    if reenviador_vivo; then
        kill "$reenviador_pid" 2>/dev/null
        wait "$reenviador_pid" 2>/dev/null
    fi
    reenviador_pid=""; reenviador_dns=""
}

# arrancar_reenviador: el dnsmasq propio de los equipos desviados, con el DNS de PIA de este tunel.
# Solo lee sus argumentos (--conf-file=/dev/null): no hace DHCP ni toca la configuracion de la casa.
arrancar_reenviador() {
    local ip inversa ahora
    reenviador_vivo && [[ "$reenviador_dns" == "$dns_pia" ]] && return 0
    ahora=$(date +%s)
    (( ahora - reenviador_intento >= REINTENTO_S )) || return 1
    reenviador_intento=$ahora
    parar_reenviador
    ip=$(lan_ip)
    [[ -n "$dns_pia" && -n "$ip" ]] || return 1
    inversa=$(printf '%s' "$ip" | awk -F. '{print $3 "." $2 "." $1 ".in-addr.arpa"}')
    mkdir -p "$ESTADO_DIR"
    dnsmasq --keep-in-foreground --conf-file=/dev/null --pid-file="$ESTADO_DIR/dns.pid" --user=dnsmasq \
        --bind-interfaces --listen-address="$ip" --port="$DNS_PUERTO" --no-resolv --no-hosts \
        --server="/$DOMINIO/$DNS_CASA" --server="/$inversa/$DNS_CASA" --server="//$DNS_CASA" \
        --server="$dns_pia" --cache-size=1000 &
    reenviador_pid=$!
    sleep 1
    if ! reenviador_vivo; then
        log "el reenviador DNS no arranco: el DNS de los equipos va directo a PIA"
        reenviador_pid=""
        return 1
    fi
    reenviador_dns=$dns_pia
    log "reenviador DNS en $ip:$DNS_PUERTO: $DOMINIO a la casa, el resto a $dns_pia"
}

destino_dns() {  # adonde va el DNS de los equipos: el reenviador si vive, si no el DNS de PIA
    if reenviador_vivo; then printf '%s:%s' "$(lan_ip)" "$DNS_PUERTO"; else printf '%s' "$dns_pia"; fi
}

# reglas_nft <macs> <destino DNS>: la tabla propia del desvio, para `nft -f -`. Se declara y se borra
# antes de crearla: el cambio es atomico y no toca las tablas del router (/etc/nftables.conf) ni las
# de Docker.
reglas_nft() {
    cat <<EOF
table inet $TABLA_NFT
delete table inet $TABLA_NFT
table inet $TABLA_NFT {
    set equipos {
        type ether_addr
        elements = { $1 }
    }
    chain marcar {
        type filter hook prerouting priority mangle + 1; policy accept;
        iifname "$LAN_IF" ether saddr @equipos meta nfproto ipv4 meta mark set $MARCA
        iifname "$LAN_IF" ether saddr @equipos meta nfproto ipv6 ip6 daddr != { fe80::/10, ff00::/8 } drop
    }
    chain dns {
        type nat hook prerouting priority dstnat - 1; policy accept;
        iifname "$LAN_IF" ether saddr @equipos meta nfproto ipv4 meta l4proto { udp, tcp } th dport 53 dnat ip to $2
    }
    chain salida {
        type nat hook postrouting priority srcnat - 1; policy accept;
        oifname "$IFACE" masquerade
    }
}
EOF
}

borrar_reglas_ip() {
    while ip rule del priority "$PRIO_SUPRIMIR" 2>/dev/null; do :; done
    while ip rule del priority "$PRIO_TUNEL" 2>/dev/null; do :; done
}

activar_desvio() {  # activar_desvio <macs>
    local dns
    dns=$(destino_dns)
    reglas_nft "$1" "$dns" | nft -f - || { log "nft rechazo la tabla del desvio"; return 1; }
    borrar_reglas_ip
    ip rule add fwmark "$MARCA" lookup main suppress_prefixlength 0 priority "$PRIO_SUPRIMIR"
    ip rule add fwmark "$MARCA" lookup "$TABLA" priority "$PRIO_TUNEL"
    ip route flush cache 2>/dev/null || true
    desvio=1; macs_aplicadas="$1"; dns_aplicado=$dns
    log "desvio activo: $1 salen por PIA ($srv_region), DNS a $dns"
}

desactivar_desvio() {  # desactivar_desvio <motivo>
    nft delete table inet "$TABLA_NFT" 2>/dev/null
    borrar_reglas_ip
    ip route flush cache 2>/dev/null || true
    if (( desvio )); then log "desvio retirado ($1): los equipos salen directo"; fi
    desvio=0; macs_aplicadas=""; dns_aplicado=""
}

# desvio_intacto: la tabla y las dos reglas siguen ahi. Una recarga de nftables, un `ip rule flush`
# o un reinicio de red pueden borrarlas sin avisar; entonces se reaplican.
desvio_intacto() {
    nft list table inet "$TABLA_NFT" >/dev/null 2>&1 \
        && ip rule show priority "$PRIO_SUPRIMIR" | grep -q . \
        && ip rule show priority "$PRIO_TUNEL" | grep -q .
}

escribir_estado() {
    local hs t
    hs=$(wg show "$IFACE" latest-handshakes 2>/dev/null | awk '{print $2; exit}')
    mkdir -p "$ESTADO_DIR"
    t=$(mktemp "$ESTADO_DIR/.estado.XXXXXX") || return 0
    {
        echo "tunel $tunel"
        echo "desvio $desvio"
        echo "equipos $(macs | awk -F', ' 'NF {print NF; exit} END {if (!NR) print 0}')"
        echo "handshake ${hs:-0}"
        echo "region ${srv_region:-ninguna}"
        echo "sondas $sondas"
        echo "perdidas $perdidas"
        echo "rtt_ms $rtt_ms"
        echo "levantamientos $levantamientos"
        echo "rechazos $rechazos"
    } > "$t"
    chmod 0644 "$t"
    mv -f "$t" "$ESTADO_DIR/estado"
}

limpiar() {
    desactivar_desvio "parada del servicio"
    parar_reenviador
    ip link del "$IFACE" 2>/dev/null
    tunel=0
    escribir_estado
}

# vuelta: una iteracion del bucle. Separada para poder probarla (tests/prueba-pia.sh).
vuelta() {
    local m ahora
    m=$(macs); ahora=$(date +%s)

    if ! ip link show "$IFACE" >/dev/null 2>&1; then
        tunel=0
        if (( ahora - ultimo_intento >= REINTENTO_S )); then
            ultimo_intento=$ahora
            levantar || true
        fi
    fi

    local responde=0
    if ip link show "$IFACE" >/dev/null 2>&1; then
        tunel_responde && responde=1
        if (( desvio )); then
            sondas=$((sondas + 1))
            (( responde )) || perdidas=$((perdidas + 1))
        fi
    fi
    if (( responde )); then
        fallos=0; tunel=1
    else
        fallos=$((fallos + 1))
        if (( fallos >= FALLOS_N )); then
            tunel=0
            (( desvio )) && desactivar_desvio "el tunel no responde"
            # Rehacer el tunel con una clave nueva: PIA olvida las claves que no ve en un tiempo
            if (( ahora - ultimo_intento >= REINTENTO_S )); then
                ultimo_intento=$ahora
                ip link del "$IFACE" 2>/dev/null
                levantar || true
            fi
        fi
    fi

    if (( tunel )) && [[ -n "$m" ]]; then
        arrancar_reenviador || true
        if (( ! desvio )) || [[ "$m" != "$macs_aplicadas" ]] || [[ "$(destino_dns)" != "$dns_aplicado" ]] \
                || ! desvio_intacto; then
            activar_desvio "$m" || true
        fi
    elif (( desvio )) && [[ -z "$m" ]]; then
        desactivar_desvio "PIA_MACS vacia"
    fi
    escribir_estado
}

# Las pruebas (tests/prueba-pia.sh) cargan las funciones sin entrar en el bucle.
[[ "${PIA_TUNEL_SIN_BUCLE:-0}" == 1 ]] && return 0

[[ -r "$CA" ]] || { log "falta el certificado de PIA en $CA"; exit 1; }
trap 'limpiar; exit 0' TERM INT
log "iniciando pia-tunel"
# Restos de una ejecucion anterior que murio sin limpiar
desactivar_desvio "arranque"
ip link del "$IFACE" 2>/dev/null

while true; do
    vuelta
    sleep "$INTERVAL" & wait $!
done
