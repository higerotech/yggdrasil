#!/usr/bin/env bash
# prueba-quorum.sh — salud de cada WAN por MAYORIA de destinos TCP en wan-balancer (check) y en
# wan-watchdog (sondear_wan), con ip, ping, curl y logger simulados. No toca la red.
# Comprueba ademas que los dos usan los mismos destinos que las sondas TLS de Heimdall.
# Uso:  bash deploy/host/tests/prueba-quorum.sh
set -uo pipefail

AQUI=$(cd "$(dirname "$0")" && pwd)
T=""
trap '[ -n "$T" ] && rm -rf "$T"' EXIT
T=$(mktemp -d)
mkdir -p "$T/bin"

cat > "$T/bin/ip" <<'EOF'
#!/usr/bin/env bash
# ip -4 -o addr show dev <iface>
n="${*: -1}"; [ -f "$STUB/ip-$n" ] && echo "2: $n    inet $(cat "$STUB/ip-$n")/24 brd x scope global $n"; exit 0
EOF
# ping SIEMPRE responde: el caso del 2026-10-06 (los ping pasan, TCP no) no debe contar
cat > "$T/bin/ping" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
d="${*: -1}"; grep -qxF -- "$d" "$STUB/falla" 2>/dev/null && exit 28; exit 0
EOF
cat > "$T/bin/logger" <<'EOF'
#!/usr/bin/env bash
echo "${*: -1}" >> "$STUB/log"
EOF
chmod +x "$T/bin/"*
export STUB="$T" PATH="$T/bin:$PATH"
echo 192.0.2.5 > "$T/ip-wan2"
: > "$T/falla"; : > "$T/log"

fallos=0
ok()    { echo "ok   $1"; }
mal()   { echo "FALLO $1"; fallos=$((fallos + 1)); }
sana()  { local d="$1"; shift; if "$@"; then ok "$d"; else mal "$d"; fi; }
caida() { local d="$1"; shift; if "$@"; then mal "$d"; else ok "$d"; fi; }
falla() { printf '%s\n' "$@" > "$T/falla"; }
lineas_log() { wc -l < "$T/log" | tr -d ' '; }

# --- wan-balancer: check ---------------------------------------------------------------
export WAN_BALANCER_SIN_BUCLE=1
# shellcheck source=../wan-balancer.sh
. "$AQUI/../wan-balancer.sh"
G="${CHECK_TLS[0]}"; C="${CHECK_TLS[1]}"; D="${CHECK_TLS[2]}"

[ "${#CHECK_ICMP[@]}" -eq 0 ] && ok "balancer: ningun ping vota" || mal "balancer: ningun ping vota"
[ "${#CHECK_TLS[@]}" -eq 3 ]  && ok "balancer: tres destinos TCP" || mal "balancer: tres destinos TCP"

falla
sana  "balancer: todo responde -> sana" check wan2
[ "$(lineas_log)" = 0 ] && ok "balancer: todo responde -> sin log" || mal "balancer: todo responde -> sin log"

falla "$G"
sana  "balancer: 2 de 3 -> sana (mayoria)" check wan2
grep -q "wan2: responden 2/3 destinos; fallan: $G" "$T/log" && ok "balancer: el fallo parcial se registra" || mal "balancer: el fallo parcial se registra"
n=$(lineas_log); check wan2
[ "$(lineas_log)" = "$n" ] && ok "balancer: el mismo fallo no se repite en el log" || mal "balancer: el mismo fallo no se repite en el log"

falla "$G" "$D"
caida "balancer: 1 de 3 -> caida, aunque los ping respondan (caso 2026-10-06)" check wan2
falla "$G" "$C" "$D"
caida "balancer: 0 de 3 -> caida" check wan2

falla
check wan2
grep -q "wan2: responden todos los destinos de salud" "$T/log" && ok "balancer: la vuelta se registra" || mal "balancer: la vuelta se registra"
caida "balancer: interfaz sin IP -> caida" check wan9

# --- wan-watchdog: sondear_wan ---------------------------------------------------------
export WAN_WATCHDOG_SIN_PRINCIPAL=1
# shellcheck source=../wan-watchdog.sh
. "$AQUI/../wan-watchdog.sh"

falla
sana  "guardian: todo responde -> sana" sondear_wan wan2
falla "$C"
sana  "guardian: 2 de 3 -> sana" sondear_wan wan2
falla "$C" "$D"
caida "guardian: 1 de 3 -> caida aunque los ping respondan" sondear_wan wan2
caida "guardian: interfaz sin IP -> caida" sondear_wan wan9

# --- Mismos destinos en balanceador, guardian y Heimdall -------------------------------
lista() { grep -E '^CHECK_(ICMP|TLS)=' "$1"; }
[ "$(lista "$AQUI/../wan-balancer.sh")" = "$(lista "$AQUI/../wan-watchdog.sh")" ] \
    && ok "guardian y balanceador usan los mismos destinos" || mal "guardian y balanceador usan los mismos destinos"

PR="$AQUI/../../prometheus/prometheus.yml"
for u in "${CHECK_TLS[@]}"; do
    h=${u#https://}; h=${h%%/*}
    for w in wan1 wan2; do
        # la linea de targets que sigue a module: [tls_<wan>]
        awk -v m="module: [tls_$w]" 'index($0, m) {f=1} f && /targets:/ {print; exit}' "$PR" | grep -qF "\"$h:443\"" \
            && ok "Heimdall sondea $h:443 por TLS en $w" || mal "Heimdall sondea $h:443 por TLS en $w"
    done
done
grep -qF 'probe_success{job=~"blackbox_tls_wan[0-9]+"}) >= bool 2' "$AQUI/../../prometheus/rules/heimdall-recording.yml" \
    && ok "wan:up = 2 de las 3 sondas TLS" || mal "wan:up = 2 de las 3 sondas TLS"

echo
[ "$fallos" -eq 0 ] && echo "todas las pruebas pasan" || { echo "$fallos prueba(s) fallan"; exit 1; }
