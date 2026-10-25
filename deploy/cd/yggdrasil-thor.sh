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
#     de la cadena de alertas. Mas los contenedores de THOR_CONTENEDORES, de fuera del proyecto
#     (Andvari, Bifrost, Hermod): esos no los vigila nadie mas, y Mimir avisa por ellos.
#   - Si Andvari (THOR_ANDVARI, su contenedor) esta sellado: en marcha pero sin abrir ninguna clave.
#   - Momento del ultimo respaldo completado de cada respaldo de THOR_RESPALDOS (nombre=marca): el de
#     Yggdrasil (yggdrasil-respaldar.sh) y los de otros servicios del host, como Bifrost.
#   - De cada disco, si es mecanico o SSD, y cuantos errores del enlace SATA o de E/S registro el
#     kernel en los ultimos 15 min. smartctl no ve que un disco se caiga del bus: el SSD de datos
#     se cayo asi el 2026-10-19 con SMART limpio.
#   - El tunel a PIA (ADR-0009), si pia-tunel.sh esta en marcha: si responde, si los equipos de
#     PIA_MACS salen por el, cuantos son, el ultimo handshake y la region.
#   - Cuando arranco el host y la temperatura del procesador. Un reinicio que nadie pidio delata un
#     cuelgue: nidavellir se congelaba sin dejar rastro en el registro (2026-10-25) y ahora la
#     reinicia su watchdog.
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
WANS=${THOR_WANS-wan1 wan2}                       # vacia en un host sin wan-balancer (nidavellir)
SMART_CADA_S=${THOR_SMART_CADA_S:-600}
DF_TIMEOUT_S=${THOR_DF_TIMEOUT_S:-15}
# Atributos SMART publicados: los que predicen fallo (5, 187, 188, 197, 198), el de cable (199)
# y contexto (9 horas, 193 ciclos de carga, 194 temperatura).
ATRIBUTOS=${THOR_ATRIBUTOS:-5 9 187 188 193 194 197 198 199}
# Mismas fuentes que el vigia de servicios: su inventario de contenedores y su lista de unidades.
INVENTARIO=${THOR_INVENTARIO:-/var/lib/yggdrasil-vigia/.inventario}
PROYECTO=${THOR_PROYECTO:-yggdrasil}
# Contenedores de midgard que no son del proyecto y se vigilan igual: la infraestructura de /srv/infra
# (Andvari, Bifrost, Hermod). Uno de la lista que no existe sale con 0.
CONTENEDORES=${THOR_CONTENEDORES:-}
# El contenedor de Andvari (OpenBao): ademas de su salud, si esta sellado. Vacio, no se mira.
ANDVARI=${THOR_ANDVARI:-}
UNIDADES=${THOR_UNIDADES:-docker.service wan-balancer.service pia-tunel.service dnsmasq.service cd-receiver.service wan-watchdog.timer yggdrasil-respaldo.timer yggdrasil-respaldo-vigia.timer yggdrasil-vigia-servicios.timer}
RESPALDO_MARCA=${THOR_RESPALDO_MARCA:-/var/lib/yggdrasil-respaldo/ultimo-exito}
RESPALDOS=${THOR_RESPALDOS:-yggdrasil=$RESPALDO_MARCA}
DOCKER_TIMEOUT_S=${THOR_DOCKER_TIMEOUT_S:-10}
JOURNAL_TIMEOUT_S=${THOR_JOURNAL_TIMEOUT_S:-10}
SYS=${THOR_SYS:-/sys}
PROC=${THOR_PROC:-/proc}
PIA_ESTADO=${THOR_PIA_ESTADO:-/run/yggdrasil-pia/estado}   # lo escribe pia-tunel.sh (ADR-0009)
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

# --- Arranque y temperatura del procesador ----------------------------------------------------
# btime de /proc/stat: segundos desde la epoca, fijo durante todo el arranque. Si cambia, el host se
# reinicio (HostReiniciado). Ilegible, no se publica.
arranque=$(awk '$1 == "btime" {print $2; exit}' "$PROC/stat" 2>/dev/null)
if [[ "$arranque" =~ ^[0-9]+$ ]]; then
    echo "# HELP yggdrasil_arranque_timestamp_seconds Momento del ultimo arranque del host."
    echo "# TYPE yggdrasil_arranque_timestamp_seconds gauge"
    echo "yggdrasil_arranque_timestamp_seconds $arranque"
fi
# El sensor del procesador: k10temp en AMD, coretemp en Intel (su temp1 es el encapsulado). Sin el,
# no se publica.
for h in "$SYS"/class/hwmon/hwmon*; do
    case "$(cat "$h/name" 2>/dev/null)" in k10temp|coretemp|zenpower) ;; *) continue ;; esac
    t=$(cat "$h/temp1_input" 2>/dev/null)
    [[ "$t" =~ ^-?[0-9]+$ ]] || continue
    echo "# HELP yggdrasil_cpu_temperatura_celsius Temperatura del procesador."
    echo "# TYPE yggdrasil_cpu_temperatura_celsius gauge"
    awk -v t="$t" 'BEGIN { printf "yggdrasil_cpu_temperatura_celsius %.1f\n", t / 1000 }'
    break
done

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
    nombres=$( { [ -r "$INVENTARIO" ] && cat "$INVENTARIO"; printf '%s\n' "$docker_ps"; printf '%s\n' $CONTENEDORES; } \
        | grep -E '^[A-Za-z0-9_.-]+$' | sort -u)
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

# --- Andvari ---------------------------------------------------------------------------------
# Sellado, Andvari sigue en marcha pero no abre ninguna clave: el gateway responde 503 a todo lo cifrado. Su
# healthcheck ya lo cuenta como no sano; esto dice ademas que es el sello, no el contenedor. `bao status`
# sale con 2 cuando esta sellado, pero escribe el estado igual. Sin respuesta legible no se publica nada:
# un 0 diria que esta abierto.
if [ -n "$ANDVARI" ]; then
    estado=$(timeout "$DOCKER_TIMEOUT_S" docker exec "$ANDVARI" bao status -format=json 2>/dev/null || true)
    sellado=""
    if printf '%s' "$estado" | grep -Eq '"sealed":[[:space:]]*true'; then sellado=1
    elif printf '%s' "$estado" | grep -Eq '"sealed":[[:space:]]*false'; then sellado=0
    fi
    if [ -n "$sellado" ]; then
        echo "# HELP yggdrasil_andvari_sellado 1 si Andvari (OpenBao) esta sellado y no abre ninguna clave."
        echo "# TYPE yggdrasil_andvari_sellado gauge"
        echo "yggdrasil_andvari_sellado $sellado"
    fi
fi

# --- Tunel PIA (ADR-0009) --------------------------------------------------------------------
# pia-tunel.sh deja su estado en /run/yggdrasil-pia/estado. El fichero desaparece con el servicio
# (RuntimeDirectory): entonces no se publica nada y avisa la unidad (yggdrasil_servicio_ok).
if [ -r "$PIA_ESTADO" ]; then
    pia() { awk -v k="$1" '$1 == k {print $2; exit}' "$PIA_ESTADO"; }
    pia_t=$(pia tunel); pia_d=$(pia desvio); pia_e=$(pia equipos); pia_h=$(pia handshake); pia_r=$(pia region)
    if [[ "$pia_t" =~ ^[01]$ && "$pia_d" =~ ^[01]$ && "$pia_e" =~ ^[0-9]+$ && "$pia_h" =~ ^[0-9]+$ ]]; then
        [[ "$pia_r" =~ ^[a-z0-9_-]+$ ]] || pia_r=desconocida
        echo "# HELP yggdrasil_pia_tunel_up 1 si el tunel a PIA responde."
        echo "# TYPE yggdrasil_pia_tunel_up gauge"
        echo "yggdrasil_pia_tunel_up $pia_t"
        echo "# HELP yggdrasil_pia_desvio_activo 1 si los equipos de PIA_MACS salen por el tunel."
        echo "# TYPE yggdrasil_pia_desvio_activo gauge"
        echo "yggdrasil_pia_desvio_activo $pia_d"
        echo "# HELP yggdrasil_pia_equipos Equipos configurados para salir por el tunel (PIA_MACS)."
        echo "# TYPE yggdrasil_pia_equipos gauge"
        echo "yggdrasil_pia_equipos $pia_e"
        echo "# HELP yggdrasil_pia_handshake_timestamp_seconds Ultimo handshake de WireGuard con PIA."
        echo "# TYPE yggdrasil_pia_handshake_timestamp_seconds gauge"
        echo "yggdrasil_pia_handshake_timestamp_seconds $pia_h"
        echo "# HELP yggdrasil_pia_region_info Region de PIA del tunel."
        echo "# TYPE yggdrasil_pia_region_info gauge"
        echo "yggdrasil_pia_region_info{region=\"$pia_r\"} 1"
        # Contadores para la revision de la ADR-0009: se reinician con el servicio (increase() lo absorbe)
        pia_s=$(pia sondas); pia_p=$(pia perdidas); pia_l=$(pia levantamientos); pia_x=$(pia rechazos); pia_rtt=$(pia rtt_ms)
        if [[ "$pia_s" =~ ^[0-9]+$ && "$pia_p" =~ ^[0-9]+$ && "$pia_l" =~ ^[0-9]+$ && "$pia_x" =~ ^[0-9]+$ ]]; then
            echo "# HELP yggdrasil_pia_sondas_total Sondas por el tunel con el desvio activo."
            echo "# TYPE yggdrasil_pia_sondas_total counter"
            echo "yggdrasil_pia_sondas_total $pia_s"
            echo "# HELP yggdrasil_pia_sondas_perdidas_total Sondas por el tunel sin respuesta, con el desvio activo."
            echo "# TYPE yggdrasil_pia_sondas_perdidas_total counter"
            echo "yggdrasil_pia_sondas_perdidas_total $pia_p"
            echo "# HELP yggdrasil_pia_levantamientos_total Veces que el tunel se ha levantado con una clave nueva."
            echo "# TYPE yggdrasil_pia_levantamientos_total counter"
            echo "yggdrasil_pia_levantamientos_total $pia_l"
            echo "# HELP yggdrasil_pia_rechazos_total Veces que PIA no dio token o rechazo la clave."
            echo "# TYPE yggdrasil_pia_rechazos_total counter"
            echo "yggdrasil_pia_rechazos_total $pia_x"
        fi
        if [[ "$pia_rtt" =~ ^[0-9]+([.][0-9]+)?$ && "$pia_rtt" != 0 ]]; then
            echo "# HELP yggdrasil_pia_rtt_ms RTT de la ultima sonda que respondio por el tunel."
            echo "# TYPE yggdrasil_pia_rtt_ms gauge"
            echo "yggdrasil_pia_rtt_ms $pia_rtt"
        fi
    fi
fi

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
