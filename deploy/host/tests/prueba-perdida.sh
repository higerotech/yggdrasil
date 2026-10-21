#!/usr/bin/env bash
# prueba-perdida.sh — ventana de perdida de wan-balancer: una WAN que responde por TCP pero pierde
# paquetes sale de la ruta, vuelve solo con la ventana limpia, un objetivo muerto no la saca, y con
# las dos fuera la ruta va por la menos mala. Con ip, ping, curl y logger simulados: no toca la red.
# Uso:  bash deploy/host/tests/prueba-perdida.sh
# La prueba lee y reinicia el estado global de wan-balancer.sh (up1, ruta1, motivo...), que
# ShellCheck no ve porque el CI no sigue el `source`.
# shellcheck disable=SC2034,SC2154
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
cat > "$T/bin/ping" <<'EOF'
#!/usr/bin/env bash
d="${*: -1}"; grep -qxF -- "$d" "$STUB/ping-falla" 2>/dev/null && exit 1; exit 0
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
: > "$T/falla"; : > "$T/ping-falla"; : > "$T/log"

fallos=0
ok()  { echo "ok   $1"; }
mal() { echo "FALLO $1"; fallos=$((fallos + 1)); }
es()  { if [ "$2" = "$3" ]; then ok "$1"; else mal "$1 (esperado $3, sale $2)"; fi; }

export WAN_BALANCER_SIN_BUCLE=1
# shellcheck source=../wan-balancer.sh
. "$AQUI/../wan-balancer.sh"

# ronda <tcp1> <tcp2> <perdidos1> <perdidos2>: una vuelta del bucle sin red. perdidosN son tres
# 0/1, uno por objetivo de PERDIDA_ICMP. Como check(), los ping solo cuentan con mayoria TCP.
# Deja la ruta aplicada en last_state, como el bucle.
ronda() {
    local i
    for i in 0 1 2; do
        (( $1 )) && registrar_ping wan1 "${PERDIDA_ICMP[$i]}" "${3:$i:1}"
        (( $2 )) && registrar_ping wan2 "${PERDIDA_ICMP[$i]}" "${4:$i:1}"
    done
    decidir "$1" "$2"
    last_state="${ruta1}${ruta2}"
}
rondas() { local n=$1 i; shift; for ((i = 0; i < n; i++)); do ronda "$@"; done; }
reiniciar() {
    fail1=0; ok1=0; up1=-1; fail2=0; ok2=0; up2=-1; preferida=""; last_state=""; ventana=()
    rondas "$VENTANA" 1 1 000 000      # arranque con las dos sanas y la ventana llena
}

# --- Piezas --------------------------------------------------------------------------------
reiniciar
es "arranque: las dos sanas -> multipath" "$last_state" 11
for i in $(seq 30); do registrar_ping wanX 1.1.1.1 1; done
es "la ventana guarda solo VENTANA resultados" "${#ventana[wanX|1.1.1.1]}" "$VENTANA"
ventana=(); registrar_ping wanX 1.1.1.1 1; registrar_ping wanX 1.1.1.1 0
es "la ventana no se vacia con menos de VENTANA resultados" "${ventana[wanX|1.1.1.1]}" 10
ventana=()
for d in "${PERDIDA_ICMP[@]}"; do for i in $(seq 5); do registrar_ping wanX "$d" 0; done; done
for i in $(seq 5); do registrar_ping wanX 8.8.8.8 1; done
registrar_ping wanX 1.1.1.1 1
es "perdidos: descarta el peor objetivo" "$(perdidos wanX)" 1
es "estado_wan: 2 fallos TCP seguidos -> fuera" "$(estado_wan 1 2 0 0 1)" 0
es "estado_wan: 1 fallo TCP -> sigue dentro" "$(estado_wan 1 1 0 0 1)" 1
es "estado_wan: 3 perdidos -> fuera" "$(estado_wan 1 0 9 3 1)" 0
es "estado_wan: TCP bien pero 2 perdidos -> sigue fuera" "$(estado_wan 0 0 9 2 1)" 0
es "estado_wan: ventana sin llenar -> sigue fuera" "$(estado_wan 0 0 9 0 0)" 0
es "estado_wan: 6 TCP bien y ventana limpia -> dentro" "$(estado_wan 0 0 6 1 1)" 1
es "menos_mala: solo una con TCP -> esa" "$(menos_mala 1 0 9 0 1)" 2
es "menos_mala: ninguna con TCP -> la actual" "$(menos_mala 2 0 0 0 0)" 2
es "menos_mala: la otra pierde 1 menos -> no cambia" "$(menos_mala 1 3 2 1 1)" 1
es "menos_mala: la otra pierde 2 menos -> cambia" "$(menos_mala 1 4 2 1 1)" 2

# --- Caso del 2026-10-21: wan2 responde por TCP y pierde un 20 % --------------------------
reiniciar
salio=""
for n in $(seq 30); do
    if (( n % 5 == 0 )); then ronda 1 1 000 111; else ronda 1 1 000 000; fi
    [[ -z "$salio" && "$last_state" == 10 ]] && salio=$n
done
[[ -n "$salio" && "$salio" -le 15 ]] && ok "20 % de perdida con TCP sano -> wan2 fuera (vuelta $salio)" \
    || mal "20 % de perdida con TCP sano -> wan2 fuera antes de la vuelta 15 (salio: ${salio:-nunca})"
grep -q "wan2: fuera (TCP .* perdidos [0-9]*/48 ping en la ventana)" "$T/log" \
    && ok "la salida por perdida se registra con su motivo" || mal "la salida por perdida se registra con su motivo"
for n in $(seq 20); do ronda 1 1 000 100; ronda 1 1 000 010; ronda 1 1 000 001; done
es "con perdida sostenida (1 de cada 3 ping, rotando objetivo) sigue fuera" "$last_state" 10
rondas 12 1 1 000 000
es "12 vueltas limpias: aun fuera (la ventana conserva la perdida)" "$last_state" 10
rondas 13 1 1 000 000
es "ventana limpia: wan2 vuelve" "$last_state" 11

# --- Lo que NO debe sacar una WAN -----------------------------------------------------------
reiniciar
rondas 60 1 1 010 000
es "un objetivo que nunca contesta no saca la WAN" "$last_state" 11
reiniciar
for n in $(seq 120); do if (( n % 40 == 0 )); then ronda 1 1 100 000; else ronda 1 1 000 000; fi; done
es "un ping perdido suelto cada 40 vueltas no saca la WAN" "$last_state" 11
reiniciar
ronda 0 1 000 000; ronda 1 1 000 000
es "un solo chequeo TCP fallido no saca la WAN" "$last_state" 11

# --- Corte duro de wan1 --------------------------------------------------------------------
reiniciar
ronda 0 1 000 000; ronda 0 1 000 000
es "2 chequeos TCP fallidos seguidos -> wan1 fuera" "$last_state" 01
rondas 5 1 1 000 000
es "5 chequeos TCP bien: aun fuera" "$last_state" 01
ronda 1 1 000 000
es "6 chequeos TCP bien: vuelve (sus ping del corte no cuentan)" "$last_state" 11

# --- Las dos fuera: la menos mala ----------------------------------------------------------
reiniciar
rondas 15 1 1 000 111
es "previo: wan2 fuera por perdida" "$last_state" 10
ronda 0 1 000 111; ronda 0 1 000 111
es "corte de wan1 con wan2 degradada: la ruta va por wan2, que al menos responde" "$last_state" 01
grep -q "las dos fuera" <<<"$motivo" && ok "el motivo dice que las dos estan fuera" || mal "el motivo dice que las dos estan fuera"
ronda 1 1 000 111
es "wan1 vuelve a responder: la ruta vuelve a wan1 sin esperar a OK_N" "$last_state" 10
ronda 0 0 000 000
es "corte de las dos: se queda la actual" "$last_state" 10
rondas 6 1 1 000 111
es "wan1 limpia y 6 TCP bien: wan1 dentro, wan2 sigue fuera" "$last_state" 10

# --- check(): los ping solo cuentan con mayoria TCP ---------------------------------------
ventana=()
printf '%s\n' 1.1.1.1 > "$T/ping-falla"; : > "$T/falla"
check wan2
es "check: con TCP sano, el ping perdido entra en la ventana" "${ventana[wan2|1.1.1.1]:-}" 1
es "check: y el que responde tambien" "${ventana[wan2|8.8.8.8]:-}" 0
printf '%s\n' "${CHECK_TLS[@]:0:2}" > "$T/falla"
check wan2
es "check: sin mayoria TCP, los ping no cuentan" "${ventana[wan2|1.1.1.1]:-}" 1

# --- Mismos objetivos que las sondas ICMP de Heimdall ---------------------------------------
PR="$AQUI/../../prometheus/prometheus.yml"
for w in wan1 wan2; do
    linea=$(awk -v m="module: [icmp_$w]" 'index($0, m) {f=1} f && /targets:/ {print; exit}' "$PR")
    for d in "${PERDIDA_ICMP[@]}"; do
        grep -qF "\"$d\"" <<<"$linea" && ok "Heimdall sondea $d por ICMP en $w" || mal "Heimdall sondea $d por ICMP en $w"
    done
    n=$(grep -o '"[^"]*"' <<<"$linea" | wc -l | tr -d ' ')
    es "Heimdall no tiene objetivos ICMP de mas en $w" "$n" "${#PERDIDA_ICMP[@]}"
done

echo
[ "$fallos" -eq 0 ] && echo "todas las pruebas pasan" || { echo "$fallos prueba(s) fallan"; exit 1; }
