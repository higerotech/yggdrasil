#!/usr/bin/env bash
# prueba-revision.sh — revisar-adr-0009.sh con Mimir y ntfy simulados (curl y hostname de prueba).
# Cada escenario da a cada consulta un valor y comprueba la propuesta del informe.
# Uso:  bash deploy/cd/tests/prueba-revision.sh   (necesita jq)
set -uo pipefail

AQUI=$(cd "$(dirname "$0")" && pwd)
REVISAR="$AQUI/../revisar-adr-0009.sh"
T=""
trap '[ -n "$T" ] && rm -rf "$T"' EXIT
T=$(mktemp -d)
mkdir -p "$T/bin"

# curl: las consultas a Mimir responden segun $STUB/valores ("subcadena de la consulta|valor", gana la
# primera que casa); el push a ntfy se guarda en $STUB/push.
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
q=""; url=""; datos=""; titulo=""
prev=""
for a in "$@"; do
  case "$prev" in
    --data-urlencode) q=${a#query=} ;;
    --data-binary) datos=${a#@} ;;
    -H) case "$a" in Title:*) titulo=$a ;; esac ;;
  esac
  case "$a" in http*) url=$a ;; esac
  prev=$a
done
if [ "$url" = "http://ntfy.prueba/tema-secreto" ]; then
  { echo "$titulo"; cat "$datos"; } > "$STUB/push"; exit 0
fi
[ -f "$STUB/mimir-caido" ] && exit 7
v=""
while IFS='|' read -r clave valor; do
  [ -n "$clave" ] || continue
  case "$q" in *"$clave"*) v=$valor; break ;; esac
done < "$STUB/valores"
if [ -n "$v" ]; then
  printf '{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[1,"%s"]}]}}\n' "$v"
else
  echo '{"status":"success","data":{"resultType":"vector","result":[]}}'
fi
EOF
printf '#!/usr/bin/env bash\necho midgard\n' > "$T/bin/hostname"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/docker"
chmod +x "$T/bin/"*
echo 'AVISO_URL=http://ntfy.prueba/tema-secreto' > "$T/aviso.env"
export STUB="$T" PATH="$T/bin:$PATH" PROM_URL="http://mimir.prueba:9090" AVISO_ENV="$T/aviso.env" \
    REVISION_DIR="$T/revisiones"

fallos=0
ok()  { echo "ok   $1"; }
mal() { echo "FALLO $1"; fallos=$((fallos + 1)); }
hay()    { if grep -qF -- "$2" "$T/salida"; then ok "$1"; else mal "$1"; fi; }
no_hay() { if grep -qF -- "$2" "$T/salida"; then mal "$1"; else ok "$1"; fi; }

# escenario <dias> <desvio %> <perdida %> <min perdida> <rtt tunel> <rechazos>: wan1 0,3 % / 55 ms y
# wan2 15 % / 37 ms, como en octubre de 2026
escenario() {
    cat > "$T/valores" <<EOF
count_over_time(yggdrasil_pia_desvio_activo|$1
avg_over_time(yggdrasil_pia_desvio_activo|$2
[30d:5m]|$4
increase(yggdrasil_pia_sondas_perdidas_total[30d])|$3
avg_over_time(yggdrasil_pia_rtt_ms|$5
levantamientos_total|3
rechazos_total|$6
job="blackbox_icmp_wan1",target|0.3
blackbox_icmp_wan1",phase|55
job="blackbox_icmp_wan2",target|15
blackbox_icmp_wan2",phase|37
EOF
}
revisar() { bash "$REVISAR" "$@" > "$T/salida" 2>&1; echo $? > "$T/rc"; }

escenario 30 99.9 0.2 10 61 0; revisar
hay "tunel sano: mantener la Fase 1" "Propuesta: MANTENER FASE 1"
hay "tunel sano: sin hallazgos" "Ninguno: el tunel cumple"
hay "el informe compara con cada WAN directa" "wan2 directa a 1.1.1.1: perdida 15.00 %, RTT medio 37.00 ms"
hay "la referencia es wan1 (la que menos pierde), no la wan2 rapida y degradada" "RTT medio 61.00 ms"

escenario 10 99.9 0.2 10 61 0; revisar
hay "10 dias de datos: insuficientes" "Propuesta: DATOS INSUFICIENTES"
hay "dice cuantos dias hay" "Solo hay 10.00 dias de datos (minimo 25)"

escenario 30 99.9 0.6 45 61 0; revisar
hay "45 min con perdida: proponer la Fase 2" "Propuesta: PROPONER FASE 2"
hay "explica la Fase 2" "45.00 min con perdida >= 1 % por el tunel (umbral 30)"

escenario 30 99.9 0.2 10 90 0; revisar
hay "el tunel tarda 35 ms mas que wan1: valorar revertir" "Propuesta: VALORAR REVERTIR"
hay "nombra la WAN de referencia" "la WAN de referencia (wan1) 55.00 ms"
hay "sugiere otra region" "probar otra region (PIA_REGION)"

escenario 30 99.9 1.2 20 61 0; revisar
hay "el tunel pierde mas que la mejor WAN mas el margen: valorar revertir" "El tunel pierde 1.20 %, la mejor WAN directa (wan1) 0.30 %"

escenario 30 97 0.2 10 61 3; revisar
hay "rechazos de PIA: hallazgo" "rechazo la clave 3.00 veces"
hay "3 % del tiempo sin tunel: horas sin desvio" "El PC salio directo, sin tunel, ~21.6 h"
hay "los hallazgos menores no cambian la propuesta" "Propuesta: MANTENER FASE 1"

touch "$T/mimir-caido"; revisar
hay "Mimir caido: sin datos" "Propuesta: SIN DATOS"
[ "$(cat "$T/rc")" = 1 ] && ok "sin datos: sale con error (el temporizador lo registra)" || mal "sin datos: sale con error"
rm "$T/mimir-caido"

escenario 30 99.9 0.2 10 61 0; revisar --aviso
[ "$(cat "$T/rc")" = 0 ] && ok "con aviso: sale bien" || mal "con aviso: sale bien"
ls "$T/revisiones"/adr-0009-*.txt >/dev/null 2>&1 && ok "el informe se guarda en REVISION_DIR" || mal "el informe se guarda en REVISION_DIR"
grep -q "Title: midgard - Revision ADR-0009: MANTENER FASE 1" "$T/push" 2>/dev/null && ok "el push lleva la propuesta en el titulo" || mal "el push lleva la propuesta en el titulo"
grep -q "Hallazgos:" "$T/push" 2>/dev/null && ok "el push lleva el informe" || mal "el push lleva el informe"
no_hay "el tema de ntfy no aparece en la salida" "tema-secreto"

echo
[ "$fallos" -eq 0 ] && echo "todas las pruebas pasan" || { echo "$fallos prueba(s) fallan"; exit 1; }
