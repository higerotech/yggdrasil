#!/usr/bin/env bash
# yggdrasil-thor.sh — Thor: metricas del host que solo existen fuera de los contenedores.
# Lo lanza yggdrasil-thor.timer cada minuto; el servicio `thor` del Compose lo sirve a Mimir.
#
#   - SMART del disco (THOR_DISCOS): atributos que anuncian su muerte. smartctl se ejecuta como
#     mucho cada THOR_SMART_CADA_S; entre medias se reutiliza la ultima lectura.
#   - Espacio de los sistemas de ficheros (THOR_PUNTOS): sobre todo el share de respaldos del NAS.
#     `df` va con timeout: un NFS `hard` colgado bloquearia el proceso para siempre. Si el punto
#     no esta montado, df devuelve el sistema de ficheros padre: se detecta y se marca como no
#     montado en vez de publicar el espacio de `/` con la etiqueta del NAS.
#   - Que WAN tiene wan-balancer en la ruta por defecto: Heimdall lo compara con wan:up.
#
# Escritura atomica (fichero temporal en el MISMO directorio + mv). El directorio se monta entero
# en el contenedor: montar el fichero suelto dejaria al contenedor leyendo el inodo viejo tras cada
# mv (asi fallo blackbox el 2026-10-06).
set -uo pipefail

DIR=${THOR_DIR:-/var/lib/yggdrasil-thor}          # se sirve entero por HTTP: solo host.prom
CACHE=${THOR_CACHE:-/var/cache/yggdrasil-thor}    # salida de smartctl (lleva el n.o de serie): fuera de DIR
DISCOS=${THOR_DISCOS:-/dev/sda}
PUNTOS=${THOR_PUNTOS:-/ /mnt/nas/respaldos}
WANS=${THOR_WANS:-wan1 wan2}
SMART_CADA_S=${THOR_SMART_CADA_S:-600}
DF_TIMEOUT_S=${THOR_DF_TIMEOUT_S:-15}
# Atributos SMART publicados: los que predicen fallo (5, 187, 188, 197, 198), el de cable (199)
# y contexto (9 horas, 193 ciclos de carga, 194 temperatura).
ATRIBUTOS=${THOR_ATRIBUTOS:-5 9 187 188 193 194 197 198 199}
AHORA=$(date +%s)

mkdir -p "$DIR" "$CACHE"
chmod 0755 "$DIR"
chmod 0700 "$CACHE"
tmp=$(mktemp "$DIR/.host.prom.XXXXXX")
trap 'rm -f "$tmp"' EXIT

etiqueta() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

{
echo "# HELP yggdrasil_thor_timestamp_seconds Momento de la ultima recoleccion de Thor."
echo "# TYPE yggdrasil_thor_timestamp_seconds gauge"
echo "yggdrasil_thor_timestamp_seconds $AHORA"

# --- SMART -----------------------------------------------------------------------------------
echo "# HELP yggdrasil_smart_atributo Valor RAW de un atributo SMART."
echo "# TYPE yggdrasil_smart_atributo gauge"
echo "# HELP yggdrasil_smart_salud 1 si smartctl -H da PASSED, 0 si no."
echo "# TYPE yggdrasil_smart_salud gauge"
echo "# HELP yggdrasil_smart_lectura_ok 1 si la ultima lectura de smartctl funciono."
echo "# TYPE yggdrasil_smart_lectura_ok gauge"
for disco in $DISCOS; do
    nombre=$(basename "$disco")
    cache="$CACHE/smart-$nombre"
    edad=$(( AHORA - $(stat -c %Y "$cache" 2>/dev/null || echo 0) ))
    if [ "$edad" -ge "$SMART_CADA_S" ]; then
        if salida=$(smartctl -H -A "$disco" 2>/dev/null) || [ -n "$salida" ]; then
            printf '%s\n' "$salida" > "$cache.nuevo" && mv -f "$cache.nuevo" "$cache"
        fi
    fi
    if [ -s "$cache" ]; then
        echo "yggdrasil_smart_lectura_ok{disco=\"$nombre\"} 1"
        if grep -q -E 'test result: PASSED|SMART Health Status: OK' "$cache"; then s=1; else s=0; fi
        echo "yggdrasil_smart_salud{disco=\"$nombre\"} $s"
        awk -v d="$nombre" -v lista=" $ATRIBUTOS " '
            $1 ~ /^[0-9]+$/ && index(lista, " " $1 " ") && $10 ~ /^[0-9]+$/ {
                printf "yggdrasil_smart_atributo{disco=\"%s\",id=\"%s\",nombre=\"%s\"} %s\n", d, $1, $2, $10
            }' "$cache"
    else
        echo "yggdrasil_smart_lectura_ok{disco=\"$nombre\"} 0"
    fi
done

# --- Espacio en disco ------------------------------------------------------------------------
echo "# HELP yggdrasil_fs_montado 1 si el punto esta montado y respondio a df a tiempo."
echo "# TYPE yggdrasil_fs_montado gauge"
echo "# HELP yggdrasil_fs_tamano_bytes Tamano del sistema de ficheros."
echo "# TYPE yggdrasil_fs_tamano_bytes gauge"
echo "# HELP yggdrasil_fs_libre_bytes Espacio disponible para usuarios sin privilegios."
echo "# TYPE yggdrasil_fs_libre_bytes gauge"
for punto in $PUNTOS; do
    p=$(etiqueta "$punto")
    # ls dispara el automount antes de df (como hace el respaldo)
    timeout "$DF_TIMEOUT_S" ls "$punto" >/dev/null 2>&1
    linea=$(timeout "$DF_TIMEOUT_S" df -B1 --output=size,avail,target "$punto" 2>/dev/null | tail -n 1)
    read -r tam libre destino <<<"$linea"
    if [ -n "${destino:-}" ] && [ "$destino" = "$punto" ] && [[ "$tam" =~ ^[0-9]+$ ]]; then
        echo "yggdrasil_fs_montado{punto=\"$p\"} 1"
        echo "yggdrasil_fs_tamano_bytes{punto=\"$p\"} $tam"
        echo "yggdrasil_fs_libre_bytes{punto=\"$p\"} $libre"
    else
        echo "yggdrasil_fs_montado{punto=\"$p\"} 0"
    fi
    unset tam libre destino
done

# --- WAN en la ruta del balanceador ----------------------------------------------------------
echo "# HELP yggdrasil_wan_en_ruta 1 si wan-balancer tiene esa WAN en la ruta por defecto."
echo "# TYPE yggdrasil_wan_en_ruta gauge"
ruta=$(ip -4 route show default 2>/dev/null)
for w in $WANS; do
    if grep -q -E "dev $w( |$)" <<<"$ruta"; then e=1; else e=0; fi
    echo "yggdrasil_wan_en_ruta{wan=\"$w\"} $e"
done
} > "$tmp"

chmod 0644 "$tmp"
mv -f "$tmp" "$DIR/host.prom"
trap - EXIT
