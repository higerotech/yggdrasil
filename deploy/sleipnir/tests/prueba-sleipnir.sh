#!/usr/bin/env bash
# prueba-sleipnir.sh — pruebas de sleipnir.sh en sus tres modos con speedtest, speedtest-cli, iperf3,
# ip, httpd y sleep simulados. No mide nada ni abre puertos. Cada caso corre el script entero
# dos ciclos (wan1 y wan2) y revisa el /metrics que deja. Uso:  bash deploy/sleipnir/tests/prueba-sleipnir.sh
set -uo pipefail

AQUI=$(cd "$(dirname "$0")" && pwd)
SLEIPNIR="$AQUI/../sleipnir.sh"
T=""
trap '[ -n "$T" ] && rm -rf "$T"' EXIT
T=$(mktemp -d)
mkdir -p "$T/bin"

# ip -4 -o addr show dev <ifc> scope global: la IP sale de $STUB/ip-<ifc>; sin fichero, sin IPv4
cat > "$T/bin/ip" <<'EOF'
#!/usr/bin/env bash
ifc=$6
[ -f "$STUB/ip-$ifc" ] || exit 0
echo "3: $ifc    inet $(cat "$STUB/ip-$ifc")/24 brd 192.0.2.255 scope global $ifc"
EOF
cat > "$T/bin/httpd" <<'EOF'
#!/usr/bin/env bash
exec /bin/sleep 60
EOF
# sleep 1 (arranque de httpd) pasa; el sleep del intervalo falla en la segunda vuelta y set -e
# termina el script con los dos ciclos ya publicados
cat > "$T/bin/sleep" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "$SLEIPNIR_INTERVALO" ] || exit 0
echo x >> "$STUB/vueltas"
[ "$(wc -l < "$STUB/vueltas")" -lt 2 ]
EOF
# CLI de Ookla: -s 1 da 800/400 ping 9; -s 2 da 940/200 ping 7 (bandwidth en bytes/s)
cat > "$T/bin/speedtest" <<'EOF'
#!/usr/bin/env bash
echo "speedtest $*" >> "$STUB/llamadas"
case " $* " in
  *" -s 1 "*) echo '{"download":{"bandwidth":100000000},"upload":{"bandwidth":50000000},"ping":{"latency":9},"server":{"id":1,"name":"Uno"}}' ;;
  *" -s 2 "*) echo '{"download":{"bandwidth":117500000},"upload":{"bandwidth":25000000},"ping":{"latency":7},"server":{"id":2,"name":"Dos Lento"}}' ;;
  *) exit 1 ;;
esac
EOF
cat > "$T/bin/speedtest-cli" <<'EOF'
#!/usr/bin/env bash
echo "speedtest-cli $*" >> "$STUB/llamadas"
[ -f "$STUB/speedtest-cli-falla" ] && exit 1
echo '{"download": 935000000, "upload": 480000000, "ping": 12.5, "server": {"id": "9"}}'
EOF
# iperf3: -R (bajada) 900 Mbps, sin -R (subida) 450 Mbps; con $STUB/iperf3-ocupado responde como
# un servidor con otra prueba en curso
cat > "$T/bin/iperf3" <<'EOF'
#!/usr/bin/env bash
echo "iperf3 $*" >> "$STUB/llamadas"
if [ -f "$STUB/iperf3-ocupado" ]; then
  echo '{"start":{},"intervals":[],"end":{},"error":"the server is busy running a test. try again later"}'; exit 1
fi
case " $* " in *" -R "*) b=900000000 ;; *) b=450000000 ;; esac
echo "{\"end\":{\"sum_sent\":{\"bits_per_second\":$b},\"sum_received\":{\"bits_per_second\":$b}}}"
EOF
chmod +x "$T/bin/"*

fallos=0
ok()  { echo "ok   $1"; }
mal() { echo "FALLO $1"; fallos=$((fallos + 1)); }
tiene()    { if grep -qF -- "$2" "$M"; then ok "$1"; else mal "$1"; fi; }
no_tiene() { if grep -qF -- "$2" "$M"; then mal "$1"; else ok "$1"; fi; }
en_log()   { if grep -qF -- "$2" "$C/log"; then ok "$1"; else mal "$1"; fi; }
llamada()  { if grep -qF -- "$2" "$C/llamadas"; then ok "$1"; else mal "$1"; fi; }

# caso <nombre> [VAR=valor ...]: dos ciclos de sleipnir.sh en un directorio limpio
caso() {
  echo "--- $1"; shift
  C="$T/caso-$RANDOM$RANDOM"; mkdir -p "$C"; touch "$C/llamadas"
  echo 192.0.2.11 > "$C/ip-wan1"; echo 192.0.2.12 > "$C/ip-wan2"
  for a in "$@"; do case "$a" in sin-ip-wan2) rm "$C/ip-wan2" ;; falla-*) touch "$C/${a#falla-}" ;; esac; done
  vars=(); for a in "$@"; do case "$a" in *=*) vars+=("$a") ;; esac; done
  env STUB="$C" PATH="$T/bin:$PATH" SLEIPNIR_DATOS="$C/datos" SLEIPNIR_INTERVALO=7 \
      SLEIPNIR_LISTEN=127.0.0.1:0 OOKLA_SERVER_ID= IPERF3_SERVER= "${vars[@]}" \
      timeout 30 sh "$SLEIPNIR" 2> "$C/log"
  [ $? = 1 ] && [ "$(wc -l < "$C/vueltas" 2>/dev/null)" = 2 ] && ok "dos ciclos y sale por el sleep simulado" \
      || mal "dos ciclos y sale por el sleep simulado (log en $C/log)"
  M="$C/datos/www/metrics"
}

caso "speedtest-cli" SLEIPNIR_MODO=speedtest
tiene "bajada wan1" 'wan_throughput_mbps{wan="wan1",direccion="down"} 935'
tiene "subida wan2" 'wan_throughput_mbps{wan="wan2",direccion="up"} 480'
tiene "latencia" 'wan_throughput_latencia_ms{wan="wan1"} 12.5'
tiene "medicion valida" 'wan_throughput_medicion_ok{wan="wan2"} 1'
llamada "origen ligado a la IP de la WAN" "speedtest-cli --source 192.0.2.12 --json"
no_tiene "nada queda en curso al terminar" 'wan_throughput_medicion_en_curso{wan="wan1"} 1'

caso "speedtest-cli falla" SLEIPNIR_MODO=speedtest falla-speedtest-cli-falla
tiene "medicion fallida" 'wan_throughput_medicion_ok{wan="wan1"} 0'
no_tiene "sin throughput inventado" 'wan_throughput_mbps{'

caso "iperf3 con puerto" SLEIPNIR_MODO=iperf3 IPERF3_SERVER=198.51.100.5:5202
tiene "bajada (-R)" 'wan_throughput_mbps{wan="wan1",direccion="down"} 900'
tiene "subida" 'wan_throughput_mbps{wan="wan1",direccion="up"} 450'
tiene "medicion valida" 'wan_throughput_medicion_ok{wan="wan2"} 1'
no_tiene "sin latencia: iperf3 no la mide" 'wan_throughput_latencia_ms{'
llamada "bajada contra el servidor y puerto, con el origen de la WAN" "iperf3 -c 198.51.100.5 -p 5202 -B 192.0.2.11 -R -t 10 -O 2 -J"
llamada "subida sin -R" "iperf3 -c 198.51.100.5 -p 5202 -B 192.0.2.12 -t 10 -O 2 -J"
en_log "log sin ping" "down=900 Mbps up=450 Mbps sin ping"

caso "iperf3 sin puerto" SLEIPNIR_MODO=iperf3 IPERF3_SERVER=198.51.100.5
llamada "puerto por defecto 5201" "iperf3 -c 198.51.100.5 -p 5201 -B 192.0.2.11 -R"

caso "iperf3 sin servidor" SLEIPNIR_MODO=iperf3
tiene "medicion fallida" 'wan_throughput_medicion_ok{wan="wan1"} 0'
en_log "lo explica en el log" "modo iperf3 sin IPERF3_SERVER"
[ -s "$C/llamadas" ] && mal "no llama a iperf3" || ok "no llama a iperf3"

caso "iperf3 servidor ocupado" SLEIPNIR_MODO=iperf3 IPERF3_SERVER=198.51.100.5 falla-iperf3-ocupado
tiene "medicion fallida" 'wan_throughput_medicion_ok{wan="wan2"} 0'
no_tiene "sin throughput" 'wan_throughput_mbps{'
en_log "el error de iperf3 llega al log" "the server is busy"

caso "ookla con dos servidores" SLEIPNIR_MODO=ookla OOKLA_SERVER_ID=1,2
tiene "maximo de bajada" 'wan_throughput_mbps{wan="wan1",direccion="down"} 940'
tiene "maximo de subida" 'wan_throughput_mbps{wan="wan1",direccion="up"} 400'
tiene "mejor ping" 'wan_throughput_latencia_ms{wan="wan2"} 7'
llamada "ligado a la interfaz" "speedtest --accept-license --accept-gdpr -I wan2 -s 2 -f json"

caso "modo por defecto" OOKLA_SERVER_ID=2
tiene "sin SLEIPNIR_MODO mide con ookla" 'wan_throughput_mbps{wan="wan2",direccion="down"} 940'

caso "modo desconocido" SLEIPNIR_MODO=iperf
tiene "medicion fallida" 'wan_throughput_medicion_ok{wan="wan1"} 0'
en_log "lo explica en el log" "SLEIPNIR_MODO desconocido: iperf"
[ -s "$C/llamadas" ] && mal "no mide con ningun modo" || ok "no mide con ningun modo"

caso "wan sin IPv4" SLEIPNIR_MODO=speedtest sin-ip-wan2
tiene "wan1 medida" 'wan_throughput_medicion_ok{wan="wan1"} 1'
tiene "wan2 omitida" 'wan_throughput_medicion_ok{wan="wan2"} 0'
en_log "lo explica en el log" "wan2 (wan2) sin IPv4"

echo
[ "$fallos" -eq 0 ] && echo "todas las pruebas pasan" || { echo "$fallos prueba(s) fallan"; exit 1; }
