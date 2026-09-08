#!/bin/sh
# Sleipnir — mide el throughput de cada WAN alternando wan1/wan2 cada ciclo y publica el
# Modos: ookla (CLI oficial, por defecto; servidor por latencia o OOKLA_SERVER_ID), speedtest
# (speedtest-cli, poco fiable: servidores lejanos y CPU), iperf3 (requiere IPERF3_SERVER).
# resultado en formato Prometheus en http://$SLEIPNIR_LISTEN/metrics (busybox httpd), que
# Mimir scrapea. Contrato: wan_throughput_mbps{wan,direccion} (RF02, RF09).
set -eu

DATOS=/var/lib/sleipnir
WWW=$DATOS/www
mkdir -p "$WWW"

: "${WAN1_IF:=wan1}" "${WAN2_IF:=wan2}" "${SLEIPNIR_MODO:=ookla}" "${OOKLA_SERVER_ID:=}"
: "${SLEIPNIR_INTERVALO:=10800}" "${SLEIPNIR_LISTEN:=172.17.0.1:9469}" "${IPERF3_SERVER:=}"

log() { echo "$(date -Iseconds) sleipnir: $*" >&2; }  # a stderr: las mediciones se capturan con $(...)

ip_de() { ip -4 -o addr show dev "$1" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1; }

# Imprime "down_mbps up_mbps ping_ms" o devuelve 1 si la medición falla.
medir_ookla() { # $1 ip  $2 interfaz -> "down up ping". OOKLA_SERVER_ID admite varios IDs separados por
  # coma: se mide contra cada uno y se devuelve el maximo por sentido (y el mejor ping). El SLO mide la
  # capacidad del enlace, y un servidor lento no debe parecer una degradacion del ISP (v0.4.5).
  ifc=$2; lista=$(printf '%s' "$OOKLA_SERVER_ID" | tr ',' ' '); [ -n "$lista" ] || lista=auto
  d=0; u=0; p=; n=0
  for s in $lista; do
    if [ "$s" = auto ]; then out=$(speedtest --accept-license --accept-gdpr -I "$ifc" -f json 2>/dev/null) || continue
    else out=$(speedtest --accept-license --accept-gdpr -I "$ifc" -s "$s" -f json 2>/dev/null) || continue; fi
    r=$(echo "$out" | jq -r '"\(.download.bandwidth*8/1000000) \(.upload.bandwidth*8/1000000) \(.ping.latency) \(.server.id) \(.server.name|gsub(" ";"_"))"' 2>/dev/null) || continue
    # shellcheck disable=SC2086
    set -- $r
    log "  ookla servidor $4 ($5): down=$1 up=$2 ping=$3 ms"
    d=$(awk -v a="$d" -v b="$1" 'BEGIN{print (b>a)?b:a}')
    u=$(awk -v a="$u" -v b="$2" 'BEGIN{print (b>a)?b:a}')
    p=$(awk -v a="${p:-$3}" -v b="$3" 'BEGIN{print (b<a)?b:a}')
    n=$((n+1))
  done
  [ "$n" -gt 0 ] || return 1
  echo "$d $u $p"
}
medir() { # $1 ip  $2 interfaz
  case "$SLEIPNIR_MODO" in
    iperf3)    medir_iperf3 "$1" ;;
    speedtest) medir_speedtest "$1" ;;
    *)         medir_ookla "$1" "$2" ;;
  esac
}

# Estado por WAN en $DATOS/<wan>.estado: OK DOWN UP PING TS (una línea).
guardar() { echo "$2 $3 $4 $5 $(date +%s)" > "$DATOS/$1.estado.tmp" && mv "$DATOS/$1.estado.tmp" "$DATOS/$1.estado"; }

# Genera /metrics agrupando cada métrica con todas sus series (formato de exposición).
generar_metrics() {
  f=$WWW/metrics.tmp
  {
    echo "# HELP wan_throughput_mbps Throughput medido por Sleipnir (Mbit/s) por WAN y direccion."
    echo "# TYPE wan_throughput_mbps gauge"
    for w in wan1 wan2; do
      [ -f "$DATOS/$w.estado" ] || continue
      read -r ok down up ping ts < "$DATOS/$w.estado"
      if [ "$ok" = 1 ]; then
        echo "wan_throughput_mbps{wan=\"$w\",direccion=\"down\"} $down"
        echo "wan_throughput_mbps{wan=\"$w\",direccion=\"up\"} $up"
      fi
    done
    echo "# HELP wan_throughput_latencia_ms Latencia reportada por la prueba de throughput (ms)."
    echo "# TYPE wan_throughput_latencia_ms gauge"
    for w in wan1 wan2; do
      [ -f "$DATOS/$w.estado" ] || continue
      read -r ok down up ping ts < "$DATOS/$w.estado"
      [ "$ok" = 1 ] && echo "wan_throughput_latencia_ms{wan=\"$w\"} $ping"
    done
    echo "# HELP wan_throughput_medicion_ok 1 si la ultima medicion fue valida, 0 si fallo."
    echo "# TYPE wan_throughput_medicion_ok gauge"
    for w in wan1 wan2; do
      [ -f "$DATOS/$w.estado" ] || continue
      read -r ok down up ping ts < "$DATOS/$w.estado"
      echo "wan_throughput_medicion_ok{wan=\"$w\"} $ok"
    done
    echo "# HELP wan_throughput_ultima_medicion_timestamp_seconds Epoch de la ultima medicion por WAN."
    echo "# TYPE wan_throughput_ultima_medicion_timestamp_seconds gauge"
    for w in wan1 wan2; do
      [ -f "$DATOS/$w.estado" ] || continue
      read -r ok down up ping ts < "$DATOS/$w.estado"
      echo "wan_throughput_ultima_medicion_timestamp_seconds{wan=\"$w\"} $ts"
    done
  } > "$f" && mv "$f" "$WWW/metrics"
}

generar_metrics
# httpd viene de busybox-extras (la busybox base de Alpine no lo incluye).
httpd -f -p "$SLEIPNIR_LISTEN" -h "$WWW" &
HTTPD=$!
trap 'kill $HTTPD 2>/dev/null' EXIT INT TERM
sleep 1
kill -0 "$HTTPD" 2>/dev/null || { log "httpd no arrancó en $SLEIPNIR_LISTEN"; exit 1; }
log "sirviendo /metrics en $SLEIPNIR_LISTEN; modo=$SLEIPNIR_MODO intervalo=${SLEIPNIR_INTERVALO}s"

ultima=$(cat "$DATOS/ultima_wan" 2>/dev/null || echo wan2)
while :; do
  if [ "$ultima" = wan1 ]; then wan=wan2; ifc=$WAN2_IF; else wan=wan1; ifc=$WAN1_IF; fi
  ip=$(ip_de "$ifc" || true)
  if [ -z "$ip" ]; then
    log "$wan ($ifc) sin IPv4; medición omitida"
    guardar "$wan" 0 0 0 0
  elif res=$(medir "$ip" "$ifc"); then
    # shellcheck disable=SC2086
    set -- $res
    log "$wan ($ip): down=${1} Mbps up=${2} Mbps ping=${3} ms"
    guardar "$wan" 1 "$1" "$2" "$3"
  else
    log "$wan ($ip): medición fallida"
    guardar "$wan" 0 0 0 0
  fi
  generar_metrics
  echo "$wan" > "$DATOS/ultima_wan"
  ultima=$wan
  sleep "$SLEIPNIR_INTERVALO"
done
