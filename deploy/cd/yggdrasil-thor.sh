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
#   - Estado de los servicios (para Hlidskjalf, el tablero de pared): los contenedores
#     permanentes del Compose, sacados del inventario que mantiene el vigia de servicios, y las
#     unidades del host. Solo se publican; el aviso sigue siendo cosa del vigia, que no depende
#     de la cadena de alertas.
#   - Momento del ultimo respaldo completado de cada respaldo de THOR_RESPALDOS (nombre=marca): el de
#     Yggdrasil (yggdrasil-respaldar.sh) y los de otros servicios del host, como Bifrost.
#   - De cada disco, si es mecanico o SSD, y cuantos errores del enlace SATA o de E/S registro el
#     kernel en los ultimos 15 min. smartctl no ve que un disco se caiga del bus: el SSD de datos
#     se cayo asi el 2026-10-19 con SMART limpio.
#
# La configuracion de cada host (discos, puntos, respaldos) va en /etc/default/yggdrasil-thor, que
# lee la unidad: este repositorio es publico y no debe llevar numeros de serie. THOR_DISCOS admite
# rutas estables (/dev/disk/by-id/...): la etiqueta `disco` es el nombre del kernel al que apuntan.
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
# Mismas fuentes que el vigia de servicios: su inventario de contenedores y su lista de unidades.
INVENTARIO=${THOR_INVENTARIO:-/var/lib/yggdrasil-vigia/.inventario}
PROYECTO=${THOR_PROYECTO:-yggdrasil}
UNIDADES=${THOR_UNIDADES:-docker.service wan-balancer.service dnsmasq.service cd-receiver.service wan-watchdog.timer yggdrasil-respaldo.timer yggdrasil-respaldo-vigia.timer yggdrasil-vigia-servicios.timer}
RESPALDO_MARCA=${THOR_RESPALDO_MARCA:-/var/lib/yggdrasil-respaldo/ultimo-exito}
RESPALDOS=${THOR_RESPALDOS:-yggdrasil=$RESPALDO_MARCA}
DOCKER_TIMEOUT_S=${THOR_DOCKER_TIMEOUT_S:-10}
JOURNAL_TIMEOUT_S=${THOR_JOURNAL_TIMEOUT_S:-10}
SYS=${THOR_SYS:-/sys}
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
    nombre=$(basename "$(readlink -f "$disco")")
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

# --- Tipo de disco y errores del kernel ------------------------------------------------------
# El puerto ATA sale de la ruta del dispositivo en /sys (.../ataN/...); sin el (NVMe, USB) solo se
# cuentan los errores de E/S del propio disco.
echo "# HELP yggdrasil_disco_rotacional 1 si el disco es mecanico, 0 si es SSD."
echo "# TYPE yggdrasil_disco_rotacional gauge"
echo "# HELP yggdrasil_disco_errores_kernel_15m Errores del enlace SATA o de E/S del disco en el registro del kernel en 15 min."
echo "# TYPE yggdrasil_disco_errores_kernel_15m gauge"
# Si journalctl falla no se publica el contador: un 0 diria que el disco esta bien sin saberlo.
if kernel=$(timeout "$JOURNAL_TIMEOUT_S" journalctl -k -q --since "-15min" --no-pager -o cat 2>/dev/null); then
    journal_ok=1
else
    journal_ok=0
fi
for disco in $DISCOS; do
    nombre=$(basename "$(readlink -f "$disco")")
    rotacional=$(cat "$SYS/block/$nombre/queue/rotational" 2>/dev/null)
    if [[ "$rotacional" =~ ^[01]$ ]]; then echo "yggdrasil_disco_rotacional{disco=\"$nombre\"} $rotacional"; fi
    [ "$journal_ok" = 1 ] || continue
    ata=$(readlink -f "$SYS/block/$nombre" 2>/dev/null | grep -o -E '/ata[0-9]+/' | tr -d / | head -n 1)
    patron="I/O error, dev ${nombre}[ ,]|EXT4-fs (error|warning) \(device $nombre"
    if [ -n "$ata" ]; then
        patron="$patron|$ata(\.[0-9]+)?: (exception|failed command|hard resetting link|link is slow|reset failed|disable device)"
    fi
    errores=$(printf '%s\n' "$kernel" | grep -c -E "$patron" || true)
    echo "yggdrasil_disco_errores_kernel_15m{disco=\"$nombre\"} ${errores:-0}"
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

# --- Servicios -------------------------------------------------------------------------------
# Contenedores: el inventario del vigia (servicios con restart, sacado del Compose) mas los que
# esten en marcha con la etiqueta del proyecto, para no depender de que el vigia haya corrido.
# Uno del inventario que no existe sale con 0. Las tareas de un solo uso (restart "no") no cuentan.
# Al recrear un contenedor, Compose renombra el viejo a <12 hex del id>_<nombre> mientras levanta el
# nuevo; ese nombre dura segundos y no es un servicio. Sin filtrarlo, una pasada de Thor durante un
# despliegue (2026-10-17, v0.5.10) publico dos servicios caidos que nunca existieron.
echo "# HELP yggdrasil_servicio_ok 1 si el contenedor esta en marcha y sano, o la unidad activa."
echo "# TYPE yggdrasil_servicio_ok gauge"
if docker_ps=$(timeout "$DOCKER_TIMEOUT_S" docker ps -a --filter "label=com.docker.compose.project=$PROYECTO" \
        --format '{{.Names}}' 2>/dev/null); then
    docker_ps=$(printf '%s\n' "$docker_ps" | grep -Ev '^[0-9a-f]{12}_' || true)
    nombres=$( { [ -r "$INVENTARIO" ] && cat "$INVENTARIO"; printf '%s\n' "$docker_ps"; } | grep -E '^[A-Za-z0-9_.-]+$' | sort -u)
    for c in $nombres; do
        s=$(timeout "$DOCKER_TIMEOUT_S" docker inspect -f \
            '{{.HostConfig.RestartPolicy.Name}} {{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' \
            "$c" 2>/dev/null) || s="- ausente -"
        read -r reinicio estado salud <<<"$s"
        [ "$reinicio" = no ] && continue
        case "$estado $salud" in
            running\ unhealthy|paused\ unhealthy) ok=0 ;;
            running\ *|paused\ *) ok=1 ;;   # paused: el respaldo congela unos segundos
            *) ok=0 ;;
        esac
        echo "yggdrasil_servicio_ok{tipo=\"contenedor\",nombre=\"$c\"} $ok"
    done
fi
for u in $UNIDADES; do
    carga=$(systemctl show -p LoadState --value "$u" 2>/dev/null)
    [ "$carga" = loaded ] || continue   # no instalada en esta maquina
    if systemctl is-active --quiet "$u"; then ok=1; else ok=0; fi
    echo "yggdrasil_servicio_ok{tipo=\"unidad\",nombre=\"$u\"} $ok"
done

# --- Respaldos -------------------------------------------------------------------------------
echo "# HELP yggdrasil_respaldo_ultimo_exito_timestamp_seconds Momento del ultimo respaldo completado."
echo "# TYPE yggdrasil_respaldo_ultimo_exito_timestamp_seconds gauge"
for r in $RESPALDOS; do
    nombre=${r%%=*}
    [[ "$nombre" =~ ^[a-z0-9_-]+$ ]] || continue
    marca=$(cat "${r#*=}" 2>/dev/null)
    if [[ "$marca" =~ ^[0-9]+$ ]]; then
        echo "yggdrasil_respaldo_ultimo_exito_timestamp_seconds{respaldo=\"$nombre\"} $marca"
    fi
done
} > "$tmp"

chmod 0644 "$tmp"
mv -f "$tmp" "$DIR/host.prom"
trap - EXIT
