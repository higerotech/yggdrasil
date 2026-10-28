#!/usr/bin/env bash
# yggdrasil-baldr.sh — Baldr: protocolo tras un arranque del host (ADR-0011).
# Lo lanza yggdrasil-baldr.service una vez por arranque, en midgard y en nidavellir.
#
# midgard no tiene UPS. Tras el apagon del 2026-10-28 (04:03 -> 11:50 UTC) el arranque dejo, sin que
# nadie avisara: dos unidades *-arranque fallidas (su base aun no estaba sana), un montaje del NAS
# caido por timeout y un contenedor parado por el, un respaldo que corrio antes de que el NAS
# respondiera y un catalogo de Fafnir hecho sin los inventarios. Cada pieza tenia su arranque; lo que
# faltaba era un orden y alguien que comprobara el resultado. Baldr lo hace en cinco fases:
#
#   0. Ventana: cuando cayo el host (ultima entrada del arranque anterior), si fue un apagado limpio
#      y cuando volvio. Antes espera a que NTP ajuste el reloj: midgard arranco el 2026-10-28 con la
#      fecha del 12-oct, y sin reloj bueno la ventana no significa nada.
#   1. Dependencias: Docker, el NAS (BALDR_NAS) y los montajes de BALDR_MONTAJES. Un montaje que
#      fallo por timeout, o que cayo porque fallo su dependencia, se reintenta: systemd no lo hace
#      solo. Los contenedores que ya corrian con un bind por debajo de un montaje recuperado se
#      reinician: Docker fija los binds al arrancar el contenedor.
#   2. Converger: las unidades *-arranque habilitadas que no terminaron bien se reintentan
#      (BALDR_REINTENTOS, separadas BALDR_PAUSA_S). Los contenedores con politica de reinicio que
#      murieron durante este arranque con codigo distinto de 0 se arrancan. Uno parado a mano antes
#      del apagon no se toca: `unless-stopped` es justo eso.
#   3. Jobs pendientes: de BALDR_JOBS, solo los que corrieron en este arranque ANTES de que las
#      dependencias estuvieran listas, o que fallaron. Los temporizadores con Persistent=true ya
#      lanzan al arrancar lo que el apagon se comio; el problema es que lo lanzan demasiado pronto.
#      Los contenedores de BALDR_CONTENEDORES se reinician tras un apagon (Sleipnir mide al arrancar).
#   4. Verificar (solo con BALDR_VERIFICAR=1, en midgard, que tiene Mimir): no antes de
#      BALDR_VERIFICAR_TRAS_S desde el arranque, las alertas activas, separando las esperables
#      (BALDR_ESPERADAS) de las demas, lo que siga mal en este host y lo que Thor publica de los
#      otros. Un push por ntfy con el resumen si hubo apagon o si queda algo pendiente.
#
# Escribe su estado en BALDR_DIR/estado (clave valor, como pia-tunel) y el resumen legible en
# BALDR_DIR/resumen. Thor publica el estado en Mimir; BaldrConPendientes y BaldrSinTerminar avisan.
#
#   yggdrasil-baldr.sh            el protocolo completo (lo que hace la unidad)
#   yggdrasil-baldr.sh verificar  solo la fase 4, sin push: para revisar a mano despues de arreglar algo
set -uo pipefail

# La unidad la carga con EnvironmentFile; a mano (`sudo yggdrasil-baldr.sh verificar`) nadie lo hace.
CONF=${BALDR_CONF:-/etc/default/yggdrasil-baldr}
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"

DIR=${BALDR_DIR:-/var/lib/yggdrasil-baldr}
PROC=${BALDR_PROC:-/proc}
NAS=${BALDR_NAS:-}
NAS_PUERTO=${BALDR_NAS_PUERTO:-2049}
ESPERA_NAS_S=${BALDR_ESPERA_NAS_S:-900}
ESPERA_MONTAJE_S=${BALDR_ESPERA_MONTAJE_S:-300}
# --list-boots lee todos los ficheros del registro: con el HDD de midgard saturado por el arranque tardo
# 3,5 min (2026-10-28 15:34). Con un tope, una ventana desconocida en vez de un Baldr colgado.
ESPERA_REGISTRO_S=${BALDR_ESPERA_REGISTRO_S:-900}
ESPERA_RELOJ_S=${BALDR_ESPERA_RELOJ_S:-300}
ESPERA_ARRANQUE_S=${BALDR_ESPERA_ARRANQUE_S:-900}
MONTAJES=${BALDR_MONTAJES:-}
REINTENTOS=${BALDR_REINTENTOS:-3}
PAUSA_S=${BALDR_PAUSA_S:-60}
JOBS=${BALDR_JOBS:-}
CONTENEDORES=${BALDR_CONTENEDORES:-}
VERIFICAR=${BALDR_VERIFICAR:-0}
VERIFICAR_TRAS_S=${BALDR_VERIFICAR_TRAS_S:-900}
ESPERADAS=${BALDR_ESPERADAS:-HostReiniciado|SleipnirSinMedicion}
PROMETHEUS=${BALDR_PROMETHEUS:-yggdrasil-prometheus}            # contenedor desde el que se consulta
PROM_URL=${BALDR_PROMETHEUS_URL:-http://127.0.0.1:9090}
AM_URL=${BALDR_ALERTMANAGER_URL:-http://yggdrasil-alertmanager:9093}
AVISO_ENV=${AVISO_ENV:-/etc/yggdrasil-aviso.env}
HOST=$(hostname -s)
MODO=${1:-todo}

mkdir -p "$DIR"
declare -A E=()
pendientes=()      # lo que sigue mal: va al resumen y cuenta para BaldrConPendientes
hechos=()          # lo que Baldr arreglo o relanzo

log() { echo "baldr: $*"; }
guardar() {        # estado atomico: Thor puede leerlo en cualquier momento
    local tmp k
    tmp=$(mktemp "$DIR/.estado.XXXXXX") || return
    for k in "${!E[@]}"; do printf '%s %s\n' "$k" "${E[$k]}"; done | sort > "$tmp"
    chmod 0644 "$tmp"; mv -f "$tmp" "$DIR/estado"
}
fase() { E[fase]=$1; guardar; log "fase $1: $2"; }
arranque_ts() { awk '$1 == "btime" {print $2; exit}' "$PROC/stat"; }
uptime_us() { awk '{printf "%d\n", $1 * 1000000}' "$PROC/uptime"; }
hhmm() { date -u -d "@$1" +%H:%M; }
duracion() { local s=$1; printf '%d h %02d min' $((s / 3600)) $((s % 3600 / 60)); }

# --- 0. Ventana del apagon ---------------------------------------------------------------------
ventana() {
    local t=0 prev id ultimo arranques
    until [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ]; do
        [ "$t" -ge "$ESPERA_RELOJ_S" ] && { pendientes+=("reloj sin sincronizar tras ${ESPERA_RELOJ_S} s: la ventana puede estar mal"); E[reloj]=0; break; }
        sleep 5; t=$((t + 5))
    done
    : "${E[reloj]:=1}"
    E[arranque]=$(arranque_ts)
    if ! arranques=$(timeout "$ESPERA_REGISTRO_S" journalctl --list-boots -o json --no-pager 2>/dev/null); then
        # Sin registro no se sabe si fue un corte: se trata como tal (Sleipnir, aviso), sin fechar la caida.
        pendientes+=("no pude leer el registro del arranque anterior en ${ESPERA_REGISTRO_S} s")
        E[apagon_inicio]=0; E[limpio]=0
        return
    fi
    prev=$(printf '%s' "$arranques" \
        | jq -r 'if length > 1 then .[-2] | "\(.boot_id) \(.last_entry)" else empty end' 2>/dev/null)
    read -r id ultimo <<<"$prev"
    if [[ "${ultimo:-}" =~ ^[0-9]+$ ]]; then
        E[apagon_inicio]=$((ultimo / 1000000))
        # Un apagado ordenado deja sus ultimas lineas; un corte de luz corta el registro donde caiga.
        if journalctl "_BOOT_ID=$id" -n 40 --no-pager -o cat 2>/dev/null \
                | grep -qE 'Journal stopped|systemd-shutdown|Reached target .*(Power-Off|Reboot|Halt)'; then
            E[limpio]=1
        else
            E[limpio]=0
        fi
    else
        E[apagon_inicio]=0; E[limpio]=1   # sin arranque anterior en el registro: nada que reconstruir
    fi
}

# --- 1. Dependencias ---------------------------------------------------------------------------
montado() {   # ls dispara el automount; findmnt confirma que hay algo montado que no es el autofs
    timeout 20 ls "$1" >/dev/null 2>&1 && findmnt -rn -o FSTYPE "$1" 2>/dev/null | grep -qvx autofs
}
# Un montaje caido no siempre queda failed. Si fallo su dependencia (el disco no aparecio antes de
# x-systemd.device-timeout), queda inactive, sin trabajo en cola, y systemd no lo vuelve a intentar.
# Asi se quedo /var/lib/bifrost en midgard el 2026-10-28 a las 18:32: 77 min sin bus de Hive. Uno
# que aun espera su fsck tiene su trabajo de arranque en cola: ese no se toca.
caido() {
    systemctl is-failed --quiet "$1" && return 0
    [ "$(systemctl is-active "$1" 2>/dev/null)" = inactive ] && [ -z "$(systemctl list-jobs --no-legend "$1" 2>/dev/null)" ]
}
# Tras recuperar un montaje, un contenedor que ya corria con un bind por debajo de el sigue viendo el
# directorio de debajo, porque Docker fija los binds al arrancarlo. bifrost-nats se quedo asi en bucle
# (mkdir /data/jetstream: permission denied). Se reinicia el que arranco antes de pedir el montaje.
rebind() {   # rebind <ruta> <hora unix en que se pidio el montaje>
    local c datos inicio fuentes s
    for c in $(docker ps -a --filter status=running --filter status=restarting --format '{{.Names}}' 2>/dev/null); do
        datos=$(docker inspect -f '{{.State.StartedAt}} {{range .Mounts}}{{if eq .Type "bind"}}{{.Source}} {{end}}{{end}}' "$c" 2>/dev/null) || continue
        read -r inicio fuentes <<<"$datos"
        inicio=$(date -u -d "$inicio" +%s 2>/dev/null || echo 0)
        [ "$inicio" -lt "$2" ] || continue
        for s in $fuentes; do
            [ "$s" = "$1" ] || [[ "$s" == "$1"/* ]] || continue
            if docker restart "$c" >/dev/null 2>&1; then
                hechos+=("contenedor $c reiniciado: corria sin $1")
            else
                pendientes+=("contenedor $c no se pudo reiniciar tras montar $1")
            fi
            break
        done
    done
}
dependencias() {
    local t p u reintentado pedido
    for _ in $(seq 1 60); do docker info >/dev/null 2>&1 && break; sleep 2; done
    docker info >/dev/null 2>&1 || pendientes+=("Docker no responde")
    if [ -n "$NAS" ]; then
        t=0
        until timeout 3 bash -c "</dev/tcp/$NAS/$NAS_PUERTO" 2>/dev/null; do
            [ "$t" -ge "$ESPERA_NAS_S" ] && { pendientes+=("el NAS ($NAS) no responde tras ${ESPERA_NAS_S} s"); break; }
            sleep 10; t=$((t + 10))
        done
        [ "$t" -gt 0 ] && [ "$t" -lt "$ESPERA_NAS_S" ] && log "el NAS respondio tras $t s"
    fi
    # Se espera a cada montaje como al NAS: un disco local pasa su fsck tras un corte y monta tarde.
    # El 2026-10-28 a las 15:31 el WD de nidavellir monto 4 s despues de que Baldr lo diera por perdido.
    # Uno caido (timeout del NAS, o su dependencia) se reintenta una vez.
    for p in $MONTAJES; do
        u=$(systemd-escape --path --suffix=mount "$p")
        t=0; reintentado=0; pedido=0
        until montado "$p"; do
            if [ "$reintentado" = 0 ] && caido "$u"; then
                pedido=$(date +%s)
                systemctl reset-failed "$u" 2>/dev/null; systemctl start "$u" 2>/dev/null; reintentado=1
                continue
            fi
            [ "$t" -ge "$ESPERA_MONTAJE_S" ] && break
            sleep 5; t=$((t + 5))
        done
        if montado "$p"; then
            if [ "$reintentado" = 1 ]; then
                hechos+=("montaje $p recuperado")
                rebind "$p" "$pedido"
            fi
        else
            pendientes+=("$p sin montar tras ${ESPERA_MONTAJE_S} s")
        fi
    done
}

# --- 2. Converger ------------------------------------------------------------------------------
converger() {
    local u t i estado c datos politica codigo fin
    for u in $(systemctl list-unit-files --type=service --state=enabled --no-legend '*-arranque.service' 2>/dev/null | awk '{print $1}'); do
        t=0
        while [ "$(systemctl is-active "$u" 2>/dev/null)" = activating ] && [ "$t" -lt "$ESPERA_ARRANQUE_S" ]; do
            sleep 10; t=$((t + 10))
        done
        estado=$(systemctl is-active "$u" 2>/dev/null)
        [ "$estado" = active ] && continue
        for i in $(seq 1 "$REINTENTOS"); do
            systemctl reset-failed "$u" 2>/dev/null
            if systemctl restart "$u" 2>/dev/null && [ "$(systemctl is-active "$u" 2>/dev/null)" = active ]; then
                hechos+=("$u convergio al reintento $i"); E[reintentados]=$(( ${E[reintentados]:-0} + 1 ))
                continue 2
            fi
            [ "$i" -lt "$REINTENTOS" ] && sleep "$PAUSA_S"
        done
        pendientes+=("$u sigue fallando tras $REINTENTOS reintentos")
    done
    # Contenedores muertos durante este arranque. FinishedAt anterior al arranque: alguien lo paro.
    for c in $(docker ps -a --filter status=exited --format '{{.Names}}' 2>/dev/null); do
        datos=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}} {{.State.ExitCode}} {{.State.FinishedAt}}' "$c" 2>/dev/null) || continue
        read -r politica codigo fin <<<"$datos"
        case "$politica" in always|unless-stopped|on-failure) ;; *) continue ;; esac
        [ "$codigo" != 0 ] || continue
        fin=$(date -u -d "$fin" +%s 2>/dev/null || echo 0)
        [ "$fin" -ge "${E[arranque]}" ] || continue
        if docker start "$c" >/dev/null 2>&1; then
            hechos+=("contenedor $c arrancado (habia salido con $codigo)")
        else
            pendientes+=("contenedor $c no arranca (salio con $codigo)")
        fi
    done
}

# --- 3. Jobs pendientes ------------------------------------------------------------------------
jobs_pendientes() {
    local listo u inicio resultado c
    listo=$(uptime_us)
    E[relanzados]=0
    for u in $JOBS; do
        inicio=$(systemctl show -p ExecMainStartTimestampMonotonic --value "$u" 2>/dev/null)
        resultado=$(systemctl show -p Result --value "$u" 2>/dev/null)
        [[ "$inicio" =~ ^[0-9]+$ ]] || continue
        [ "$inicio" -gt 0 ] || continue                       # no corrio en este arranque: nada perdido
        if [ "$inicio" -lt "$listo" ] || [ "$resultado" != success ]; then
            systemctl reset-failed "$u" 2>/dev/null
            if systemctl start "$u" 2>/dev/null; then
                hechos+=("$u relanzado"); E[relanzados]=$(( ${E[relanzados]} + 1 ))
            else
                pendientes+=("$u fallo al relanzarlo: journalctl -u $u")
            fi
        fi
    done
    if [ "${E[limpio]}" = 0 ]; then
        for c in $CONTENEDORES; do
            docker restart "$c" >/dev/null 2>&1 && hechos+=("contenedor $c reiniciado") \
                || pendientes+=("contenedor $c no se pudo reiniciar")
        done
    fi
}

# --- 4. Verificar ------------------------------------------------------------------------------
consulta() {   # consulta <url completa>: desde el contenedor de Prometheus, que ve a Alertmanager
    docker exec "$PROMETHEUS" wget -qO- "$1" 2>/dev/null
}
verificar() {
    local falta alertas q
    falta=$(( ${E[arranque]:-$(arranque_ts)} + VERIFICAR_TRAS_S - $(date +%s) ))
    [ "$MODO" = todo ] && [ "$falta" -gt 0 ] && { log "verifico en $falta s"; sleep "$falta"; }
    esperadas=(); inesperadas=()
    if alertas=$(consulta "$AM_URL/api/v2/alerts?active=true&silenced=false&inhibited=false"); then
        while IFS=$'\t' read -r nombre detalle; do
            [ -n "$nombre" ] || continue
            [[ "$nombre" == BaldrConPendientes || "$nombre" == BaldrSinTerminar ]] && continue
            if [[ "$nombre" =~ ^($ESPERADAS)$ ]]; then esperadas+=("$nombre$detalle"); else inesperadas+=("$nombre$detalle"); fi
        done < <(printf '%s' "$alertas" | jq -r '.[] | [.labels.alertname,
            ((if .labels.wan then " " + .labels.wan else "" end) + (if .labels.host then " (" + .labels.host + ")" else "" end)
             + (if .labels.nombre then " " + .labels.nombre else "" end))] | @tsv' 2>/dev/null | sort -u)
        for a in "${inesperadas[@]}"; do pendientes+=("alerta $a"); done
    else
        pendientes+=("no pude consultar Gjallarhorn")
    fi
    # Otros hosts: lo que su Baldr dejo pendiente o no termino, segun Thor
    q='yggdrasil_baldr_pendientes{host!=""} > 0 or (yggdrasil_baldr_terminado_timestamp_seconds{host!=""} < yggdrasil_arranque_timestamp_seconds{host!=""})'
    while read -r h; do
        [ -n "$h" ] && pendientes+=("$h: Baldr con pendientes o sin terminar (cat /var/lib/yggdrasil-baldr/resumen)")
    done < <(consulta "$PROM_URL/api/v1/query?query=$(jq -rn --arg q "$q" '$q|@uri')" \
        | jq -r '.data.result[].metric.host' 2>/dev/null | sort -u)
}

locales() {   # lo que sigue mal en este host al terminar, salvo lo que ya esta en la lista
    local u
    while read -r u; do
        [ -n "$u" ] || continue
        printf '%s\n' "${pendientes[@]}" | grep -qF "$u" || pendientes+=("unidad $u fallida")
    done < <(systemctl list-units --failed --plain --no-legend 2>/dev/null | awk '{print $1}')
    # Un contenedor en bucle de reinicios o unhealthy: para `docker ps` esta vivo y su *-arranque
    # termino bien. bifrost-nats paso asi 77 min el 2026-10-28 y el resumen decia que todo iba bien.
    while read -r u; do
        [ -n "$u" ] && pendientes+=("contenedor $u en bucle de reinicios")
    done < <(docker ps -a --filter status=restarting --format '{{.Names}}' 2>/dev/null)
    while read -r u; do
        [ -n "$u" ] && pendientes+=("contenedor $u unhealthy")
    done < <(docker ps --filter health=unhealthy --format '{{.Names}}' 2>/dev/null)
}

resumen() {
    local f="$DIR/resumen" dur=""
    if [ "${E[limpio]}" = 0 ] && [ "${E[apagon_inicio]}" -gt 0 ]; then
        dur="Apagon de $(duracion $(( ${E[arranque]} - ${E[apagon_inicio]} ))) ($(hhmm "${E[apagon_inicio]}") -> $(hhmm "${E[arranque]}") UTC)."
    elif [ "${E[limpio]}" = 1 ]; then
        dur="Reinicio ordenado; volvio a las $(hhmm "${E[arranque]}") UTC."
    else
        dur="Arranque tras un corte; volvio a las $(hhmm "${E[arranque]}") UTC, sin hora de caida."
    fi
    {
        echo "$HOST: $dur"
        [ "${#hechos[@]}" -gt 0 ] && { echo "Hecho:"; printf -- '- %s\n' "${hechos[@]}"; }
        [ "${#esperadas[@]}" -gt 0 ] && { echo "Esperables tras el arranque:"; printf -- '- %s\n' "${esperadas[@]}"; }
        if [ "${#pendientes[@]}" -gt 0 ]; then echo "Pendiente:"; printf -- '- %s\n' "${pendientes[@]}"
        else echo "Nada pendiente."; fi
    } > "$f.nuevo" && mv -f "$f.nuevo" "$f"
    cat "$f"
}

avisar() {
    local titulo prioridad etiquetas
    [ "$VERIFICAR" = 1 ] && [ "$MODO" = todo ] || return 0
    [ "${E[limpio]}" = 0 ] || [ "${#pendientes[@]}" -gt 0 ] || return 0
    [ -r "$AVISO_ENV" ] || { log "sin $AVISO_ENV: no aviso"; return 0; }
    # shellcheck disable=SC1090
    . "$AVISO_ENV"
    [ -n "${AVISO_URL:-}" ] || return 0
    if [ "${#pendientes[@]}" -gt 0 ]; then
        titulo="Tras el arranque: ${#pendientes[@]} pendiente(s)"; prioridad=high; etiquetas="warning,electric_plug"
    else
        titulo="Tras el arranque: todo en orden"; prioridad=default; etiquetas="white_check_mark,electric_plug"
    fi
    curl -fsS -m 20 --retry 3 --retry-delay 10 --retry-all-errors \
        -H "Title: $HOST - $titulo" -H "Priority: $prioridad" -H "Tags: $etiquetas" \
        --data-binary "@$DIR/resumen" "$AVISO_URL" >/dev/null && log "aviso enviado"
}

# --- Principal ---------------------------------------------------------------------------------
esperadas=(); inesperadas=()
if [ "$MODO" = verificar ]; then
    # Revision a mano: conserva la ventana y lo hecho por la pasada automatica de este arranque. Sin
    # ella (Baldr recien instalado, o su estado es de un arranque anterior) la calcula: no supone nada.
    if [ -r "$DIR/estado" ]; then
        while read -r k v; do [ -n "$k" ] && E[$k]=$v; done < "$DIR/estado"
    fi
    [ "${E[arranque]:-}" = "$(arranque_ts)" ] || ventana
    # Las alertas solo las mira el host que tiene Mimir (BALDR_VERIFICAR=1); los demas, lo suyo.
    [ "$VERIFICAR" = 1 ] && verificar
    locales
else
    E=([fase]=0 [terminado]=0 [pendientes]=0 [relanzados]=0 [reintentados]=0)
    guardar
    fase 0 "ventana del apagon"; ventana; guardar
    fase 1 "dependencias";       dependencias
    fase 2 "converger";          converger
    fase 3 "jobs pendientes";    jobs_pendientes
    if [ "$VERIFICAR" = 1 ]; then fase 4 "verificar"; verificar; fi
    locales
fi
E[pendientes]=${#pendientes[@]}
E[terminado]=$(date +%s)
E[fase]=5
guardar
resumen
avisar
exit 0
