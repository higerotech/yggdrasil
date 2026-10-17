#!/usr/bin/env bash
# prueba-thor.sh — pruebas de yggdrasil-thor.sh con smartctl, df, timeout e ip simulados.
# No toca el disco ni la red. Uso:  bash deploy/cd/tests/prueba-thor.sh
set -uo pipefail

AQUI=$(cd "$(dirname "$0")" && pwd)
THOR="$AQUI/../yggdrasil-thor.sh"
T=""
trap '[ -n "$T" ] && rm -rf "$T"' EXIT
T=$(mktemp -d)
mkdir -p "$T/bin" "$T/pub" "$T/cache"

cat > "$T/smart.txt" <<'EOF'
smartctl 7.4 2023-08-01 r5530 [x86_64-linux-6.8.0] (local build)
=== START OF READ SMART DATA SECTION ===
SMART overall-health self-assessment test result: PASSED

=== START OF READ SMART DATA SECTION ===
SMART Attributes Data Structure revision number: 10
ID# ATTRIBUTE_NAME          FLAG     VALUE WORST THRESH TYPE      UPDATED  WHEN_FAILED RAW_VALUE
  1 Raw_Read_Error_Rate     0x000f   111   099   006    Pre-fail  Always       -       37254704
  5 Reallocated_Sector_Ct   0x0033   100   100   036    Pre-fail  Always       -       0
  9 Power_On_Hours          0x0032   057   057   000    Old_age   Always       -       37968
187 Reported_Uncorrect      0x0032   001   001   000    Old_age   Always       -       1375
193 Load_Cycle_Count        0x0032   001   001   000    Old_age   Always       -       609732
194 Temperature_Celsius     0x0022   038   045   000    Old_age   Always       -       38 (0 14 0 0 0)
197 Current_Pending_Sector  0x0012   100   100   000    Old_age   Always       -       16
198 Offline_Uncorrectable   0x0010   100   100   000    Old_age   Offline      -       16
199 UDMA_CRC_Error_Count    0x003e   200   001   000    Old_age   Always       -       229963
EOF

# smartctl sale con 4 o 64 cuando el registro de errores tiene entradas aunque haya leido bien
cat > "$T/bin/smartctl" <<'EOF'
#!/usr/bin/env bash
echo llamada >> "$STUB/smartctl.log"
[ -f "$STUB/smartctl-falla" ] && exit 2
cat "$STUB/smart.txt"; exit 64
EOF
cat > "$T/bin/timeout" <<'EOF'
#!/usr/bin/env bash
shift; exec "$@"
EOF
# df -B1 --output=size,avail,target <punto>
cat > "$T/bin/df" <<'EOF'
#!/usr/bin/env bash
p="${*: -1}"
[ -f "$STUB/df-cuelga" ] && [ "$p" = /mnt/nas/respaldos ] && exit 124
echo "     1B-blocks         Avail Mounted on"
case "$p" in
  /) echo "490000000000 440000000000 /" ;;
  /mnt/nas/respaldos)
     if [ -f "$STUB/nas-montado" ]; then echo "3600000000000 173000000000 /mnt/nas/respaldos"
     else echo "490000000000 440000000000 /"; fi ;;
esac
EOF
cat > "$T/bin/ip" <<'EOF'
#!/usr/bin/env bash
cat "$STUB/ruta"
EOF
# docker ps -a ... --format '{{.Names}}'  /  docker inspect -f '...' <nombre>
# $STUB/contenedores: "<nombre> <restart> <estado> <salud>" por linea
cat > "$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
[ -f "$STUB/docker-caido" ] && exit 1
case "$1" in
  ps) awk '{print $1}' "$STUB/contenedores" ;;
  inspect) l=$(grep "^${*: -1} " "$STUB/contenedores") || exit 1; echo "${l#* }" ;;
esac
EOF
# systemctl show -p LoadState --value <u>  /  systemctl is-active --quiet <u>
# $STUB/unidades: "<unidad> <activa|inactiva>"; las que no estan, not-found
cat > "$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
u="${*: -1}"; l=$(grep "^$u " "$STUB/unidades")
case "$1" in
  show) [ -n "$l" ] && echo loaded || echo not-found ;;
  is-active) [ "${l#* }" = activa ] ;;
esac
EOF
chmod +x "$T/bin/"*
echo "default via 192.168.1.1 dev wan1 " > "$T/ruta"
touch "$T/nas-montado"
printf '%s\n' "yggdrasil-grafana always running healthy" "yggdrasil-prometheus unless-stopped running -" \
    "yggdrasil-node-red unless-stopped running unhealthy" "yggdrasil-mosquitto unless-stopped exited -" \
    "yggdrasil-prometheus-pausado unless-stopped paused -" "yggdrasil-node-red-init no exited -" > "$T/contenedores"
printf '%s\n' yggdrasil-grafana yggdrasil-alertmanager > "$T/inventario"   # alertmanager: no existe
printf '%s\n' "docker.service activa" "wan-balancer.service inactiva" > "$T/unidades"
echo 1792180000 > "$T/ultimo-exito"

export STUB="$T" PATH="$T/bin:$PATH" THOR_DIR="$T/pub" THOR_CACHE="$T/cache" THOR_SMART_CADA_S=600 \
    THOR_INVENTARIO="$T/inventario" THOR_RESPALDO_MARCA="$T/ultimo-exito"
fallos=0
ok()  { echo "ok   $1"; }
mal() { echo "FALLO $1"; fallos=$((fallos + 1)); }
tiene()    { if grep -qF -- "$2" "$T/pub/host.prom"; then ok "$1"; else mal "$1"; fi; }
no_tiene() { if grep -qF -- "$2" "$T/pub/host.prom"; then mal "$1"; else ok "$1"; fi; }
pasada() { bash "$THOR" || mal "el recolector salio con error"; }

pasada
tiene "marca de tiempo" "yggdrasil_thor_timestamp_seconds "
tiene "pendientes = 16" 'yggdrasil_smart_atributo{disco="sda",id="197",nombre="Current_Pending_Sector"} 16'
tiene "errores de cable" 'yggdrasil_smart_atributo{disco="sda",id="199",nombre="UDMA_CRC_Error_Count"} 229963'
tiene "temperatura sin el detalle entre parentesis" 'yggdrasil_smart_atributo{disco="sda",id="194",nombre="Temperature_Celsius"} 38'
no_tiene "atributos fuera de la lista no se publican" 'id="1",'
tiene "salud PASSED aunque smartctl salga con 64" 'yggdrasil_smart_salud{disco="sda"} 1'
tiene "lectura ok" 'yggdrasil_smart_lectura_ok{disco="sda"} 1'
tiene "NAS montado" 'yggdrasil_fs_montado{punto="/mnt/nas/respaldos"} 1'
tiene "NAS libre" 'yggdrasil_fs_libre_bytes{punto="/mnt/nas/respaldos"} 173000000000'
tiene "raiz" 'yggdrasil_fs_tamano_bytes{punto="/"} 490000000000'
tiene "wan1 en la ruta" 'yggdrasil_wan_en_ruta{wan="wan1"} 1'
tiene "wan2 fuera de la ruta" 'yggdrasil_wan_en_ruta{wan="wan2"} 0'
[ "$(stat -c %a "$T/pub/host.prom")" = 644 ] && ok "host.prom legible (644)" || mal "host.prom legible (644)"
[ -z "$(find "$T/pub" -name '.host.prom.*')" ] && ok "sin temporales en el directorio servido" || mal "sin temporales en el directorio servido"
[ -z "$(find "$T/pub" -name 'smart*')" ] && [ -s "$T/cache/smart-sda" ] && ok "la cache de smartctl queda fuera del directorio servido" || mal "la cache de smartctl queda fuera del directorio servido"
tiene "contenedor sano" 'yggdrasil_servicio_ok{tipo="contenedor",nombre="yggdrasil-grafana"} 1'
tiene "contenedor sin healthcheck en marcha" 'yggdrasil_servicio_ok{tipo="contenedor",nombre="yggdrasil-prometheus"} 1'
tiene "contenedor unhealthy" 'yggdrasil_servicio_ok{tipo="contenedor",nombre="yggdrasil-node-red"} 0'
tiene "contenedor parado" 'yggdrasil_servicio_ok{tipo="contenedor",nombre="yggdrasil-mosquitto"} 0'
tiene "contenedor en pausa (respaldo) cuenta como en marcha" 'yggdrasil_servicio_ok{tipo="contenedor",nombre="yggdrasil-prometheus-pausado"} 1'
tiene "contenedor del inventario que no existe" 'yggdrasil_servicio_ok{tipo="contenedor",nombre="yggdrasil-alertmanager"} 0'
no_tiene "tarea de un solo uso (restart no) fuera" 'nombre="yggdrasil-node-red-init"'
tiene "unidad activa" 'yggdrasil_servicio_ok{tipo="unidad",nombre="docker.service"} 1'
tiene "unidad inactiva" 'yggdrasil_servicio_ok{tipo="unidad",nombre="wan-balancer.service"} 0'
no_tiene "unidad no instalada se salta" 'nombre="dnsmasq.service"'
tiene "ultimo respaldo" 'yggdrasil_respaldo_ultimo_exito_timestamp_seconds 1792180000'

pasada
[ "$(wc -l < "$T/smartctl.log")" = 1 ] && ok "segunda pasada: reutiliza la cache, no llama a smartctl" || mal "segunda pasada: reutiliza la cache"

printf 'default \n\tnexthop via 192.168.1.1 dev wan1 weight 1 \n\tnexthop via 192.168.2.1 dev wan2 weight 1 \n' > "$T/ruta"
pasada
tiene "multipath: wan1 en la ruta" 'yggdrasil_wan_en_ruta{wan="wan1"} 1'
tiene "multipath: wan2 en la ruta" 'yggdrasil_wan_en_ruta{wan="wan2"} 1'

rm "$T/nas-montado"
pasada
tiene "NAS sin montar: df devuelve / y se marca como no montado" 'yggdrasil_fs_montado{punto="/mnt/nas/respaldos"} 0'
no_tiene "NAS sin montar: no publica el espacio de / con la etiqueta del NAS" 'yggdrasil_fs_libre_bytes{punto="/mnt/nas/respaldos"}'

touch "$T/nas-montado" "$T/df-cuelga"
pasada
tiene "df colgado (timeout): no montado" 'yggdrasil_fs_montado{punto="/mnt/nas/respaldos"} 0'
rm "$T/df-cuelga"

rm -f "$T/cache/smart-sda"; touch "$T/smartctl-falla"
pasada
tiene "smartctl sin salida y sin cache: lectura fallida" 'yggdrasil_smart_lectura_ok{disco="sda"} 0'
no_tiene "smartctl sin salida: no inventa atributos" 'yggdrasil_smart_atributo{'

touch "$T/docker-caido"; echo basura > "$T/ultimo-exito"
pasada
no_tiene "docker caido: no publica contenedores" 'tipo="contenedor"'
tiene "docker caido: las unidades siguen" 'yggdrasil_servicio_ok{tipo="unidad",nombre="docker.service"} 1'
grep -q '^yggdrasil_respaldo_ultimo_exito_timestamp_seconds' "$T/pub/host.prom" \
    && mal "marca de respaldo no numerica: no se publica" || ok "marca de respaldo no numerica: no se publica"

echo
[ "$fallos" -eq 0 ] && echo "todas las pruebas pasan" || { echo "$fallos prueba(s) fallan"; exit 1; }
