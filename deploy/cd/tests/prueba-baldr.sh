#!/usr/bin/env bash
# prueba-baldr.sh — pruebas de yggdrasil-baldr.sh con systemctl, journalctl, docker y curl simulados.
# Reproduce el apagon del 2026-10-28. No toca el sistema ni la red. Necesita jq y date de GNU.
# Uso:  bash deploy/cd/tests/prueba-baldr.sh
set -uo pipefail

AQUI=$(cd "$(dirname "$0")" && pwd)
BALDR="$AQUI/../yggdrasil-baldr.sh"
T=""
trap '[ -n "$T" ] && rm -rf "$T"' EXIT
T=$(mktemp -d)

stubs() {
mkdir -p "$T/bin"
cat > "$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$STUB/llamadas"
u="${*: -1}"
case "$1" in
  is-failed) grep -qx "$u" "$STUB/montajes-fallidos" 2>/dev/null ;;
  reset-failed) [ -f "$STUB/montajes-fallidos" ] && sed -i "/^$u\$/d" "$STUB/montajes-fallidos"; exit 0 ;;
  start)
    case "$u" in
      *.mount) [ -f "$STUB/montable-$u" ] && touch "$STUB/montado-$u"; exit 0 ;;
      *) [ -f "$STUB/job-falla-$u" ] && exit 1; exit 0 ;;
    esac ;;
  list-unit-files) cat "$STUB/arranques" 2>/dev/null ;;
  is-active) cat "$STUB/estado-$u" 2>/dev/null || echo inactive ;;
  restart) [ -f "$STUB/arreglable-$u" ] && echo active > "$STUB/estado-$u"; [ "$(cat "$STUB/estado-$u")" = active ] ;;
  show) l=$(grep "^$u " "$STUB/jobs" 2>/dev/null); read -r _ inicio resultado <<<"$l"
        case "$3" in ExecMainStartTimestampMonotonic) echo "${inicio:-0}" ;; Result) echo "${resultado:-success}" ;; esac ;;
  list-units) cat "$STUB/unidades-fallidas" 2>/dev/null ;;
esac
EOF
cat > "$T/bin/journalctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *list-boots*) [ -f "$STUB/registro-cuelga" ] && exit 124; cat "$STUB/boots.json" ;;
  *_BOOT_ID=*) cat "$STUB/ultimas" ;;
esac
EOF
# $STUB/salidos: "<nombre> <politica> <codigo> <FinishedAt>"
cat > "$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$STUB/llamadas"
case "$1" in
  info) exit 0 ;;
  ps) awk '{print $1}' "$STUB/salidos" 2>/dev/null ;;
  inspect) l=$(grep "^${*: -1} " "$STUB/salidos") || exit 1; echo "${l#* }" ;;
  start) [ "$2" != roto ] ;;
  restart) exit 0 ;;
  exec) case "${*: -1}" in *api/v2/alerts*) cat "$STUB/am.json" ;; *api/v1/query*) cat "$STUB/prom.json" ;; esac ;;
esac
EOF
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STUB/curl.log"
for a; do case "$a" in @*) cp "${a#@}" "$STUB/push.txt" ;; esac; done
EOF
cat > "$T/bin/findmnt" <<'EOF'
#!/usr/bin/env bash
b=$(basename "${*: -1}")
# $STUB/tarde-<unidad>: cuantas consultas mas tarda en montar (un disco que pasa su fsck)
if [ -f "$STUB/tarde-$b.mount" ]; then
    n=$(cat "$STUB/tarde-$b.mount")
    if [ "$n" -gt 0 ]; then echo $((n - 1)) > "$STUB/tarde-$b.mount"; exit 1; fi
    echo ext4; exit 0
fi
[ -f "$STUB/montado-$b.mount" ] && echo nfs4 || echo autofs
EOF
printf '#!/usr/bin/env bash\necho "$(basename "${*: -1}").mount"\n' > "$T/bin/systemd-escape"
printf '#!/usr/bin/env bash\necho yes\n' > "$T/bin/timedatectl"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/sleep"
printf '#!/usr/bin/env bash\nshift; exec "$@"\n' > "$T/bin/timeout"
chmod +x "$T/bin/"*
}

fallos=0
ok()  { echo "ok   $1"; }
mal() { echo "FALLO $1"; fallos=$((fallos + 1)); }
estado() { awk -v k="$1" '$1 == k {print $2}' "$T/baldr/estado"; }
igual()   { local v; v=$(estado "$2"); if [ "$v" = "$3" ]; then ok "$1"; else mal "$1 ($2=$v, esperaba $3)"; fi; }
llamo()   { if grep -qF -- "$2" "$T/llamadas"; then ok "$1"; else mal "$1"; fi; }
no_llamo(){ if grep -qF -- "$2" "$T/llamadas"; then mal "$1"; else ok "$1"; fi; }
resumen() { if grep -qF -- "$2" "$T/baldr/resumen"; then ok "$1"; else mal "$1 (resumen: $(head -1 "$T/baldr/resumen"))"; fi; }

preparar() {   # un host recien arrancado: sin rastro de la pasada anterior
    rm -rf "$T/baldr" "$T/proc" "$T"/montad* "$T"/estado-* "$T"/arreglable-* "$T"/job-falla-* \
        "$T/llamadas" "$T/curl.log" "$T/push.txt"
    mkdir -p "$T/proc" "$T/nas/respaldos" "$T/nas/descargas" "$T/nas/media"
    arranque=$(date -u -d 2026-10-28T11:50:46Z +%s)
    printf '%s\n' "cpu  1 2 3" "btime $arranque" > "$T/proc/stat"
    echo "600.00 1100.00" > "$T/proc/uptime"   # Baldr listo a los 600 s del arranque
    caida=$(date -u -d 2026-10-28T04:03:50Z +%s)
    # el ultimo de la lista es el arranque en curso; el penultimo, el que cayo
    printf '[{"boot_id":"aaa","last_entry":%s},{"boot_id":"bbb","last_entry":%s},{"boot_id":"ccc","last_entry":%s}]\n' \
        "$((caida - 86400))000000" "${caida}000000" "$((arranque + 600))000000" > "$T/boots.json"
    : > "$T/llamadas"
}

stubs
export STUB="$T" PATH="$T/bin:$PATH" BALDR_DIR="$T/baldr" BALDR_PROC="$T/proc" BALDR_PAUSA_S=0 \
    BALDR_VERIFICAR_TRAS_S=0 AVISO_ENV="$T/aviso.env" BALDR_CONF="$T/sin-conf" BALDR_ESPERA_MONTAJE_S=30
echo "AVISO_URL=https://ntfy.example/tema" > "$T/aviso.env"

# --- 1. El apagon del 2026-10-28 ---------------------------------------------------------------
preparar
# un corte de luz: el registro termina donde cayo, sin la secuencia de apagado
printf '%s\n' "Starting morocota-vigia.service - morocota: avisa por ntfy si el sandbox falla..." > "$T/ultimas"
# respaldos montado; descargas fallo por timeout y se recupera; media fallo y no vuelve
touch "$T/montado-respaldos.mount" "$T/montable-descargas.mount"
printf '%s\n' descargas.mount media.mount > "$T/montajes-fallidos"
# yggdrasil-arranque fallo (Nornas aun no sano) y converge al reintentar; ves-market sigue fallando
printf '%s\n' "yggdrasil-arranque.service enabled enabled" "ves-market-arranque.service enabled enabled" \
    "andvari-arranque.service enabled enabled" > "$T/arranques"
echo failed > "$T/estado-yggdrasil-arranque.service"; touch "$T/arreglable-yggdrasil-arranque.service"
echo failed > "$T/estado-ves-market-arranque.service"
echo active > "$T/estado-andvari-arranque.service"
# transmission murio en este arranque (128); "manual" se paro antes del apagon; "init" es de un solo uso
printf '%s\n' "transmission unless-stopped 128 2026-10-28T11:59:31.5Z" \
    "manual unless-stopped 137 2026-10-20T00:00:00Z" "init no 1 2026-10-28T11:58:00Z" \
    "roto always 1 2026-10-28T11:58:00Z" > "$T/salidos"
# jobs: <unidad> <inicio monotonic us> <resultado>. listo = 600 s
printf '%s\n' "fafnir-catalogo.service 100000000 success" "yggdrasil-respaldo.service 0 success" \
    "bragi-respaldo.service 700000000 success" "ves-market-respaldo-nas.service 800000000 exit-code" \
    "hermod-respaldo.service 200000000 success" > "$T/jobs"
touch "$T/job-falla-hermod-respaldo.service"
cat > "$T/am.json" <<'EOF'
[{"labels":{"alertname":"HostReiniciado","severity":"warning"}},
 {"labels":{"alertname":"SleipnirSinMedicion","wan":"wan1"}},
 {"labels":{"alertname":"NasNoMontado","severity":"critical"}},
 {"labels":{"alertname":"BaldrConPendientes","host":"nidavellir"}}]
EOF
echo '{"data":{"result":[{"metric":{"host":"nidavellir"},"value":[0,"1"]}]}}' > "$T/prom.json"
echo "unidad-vieja.service loaded failed failed Algo que fallo y nadie arreglo" > "$T/unidades-fallidas"

BALDR_MONTAJES="$T/nas/respaldos $T/nas/descargas $T/nas/media" BALDR_CONTENEDORES="yggdrasil-throughput-probe" \
BALDR_JOBS="yggdrasil-respaldo.service hermod-respaldo.service ves-market-respaldo-nas.service fafnir-catalogo.service bragi-respaldo.service" \
BALDR_VERIFICAR=1 BALDR_NAS=127.0.0.1 BALDR_NAS_PUERTO=9 BALDR_ESPERA_NAS_S=0 \
    bash "$BALDR" > "$T/salida" 2>&1 || mal "baldr salio con error"

igual "apagon: corte de luz, no apagado limpio" limpio 0
igual "apagon: la caida es la ultima entrada del arranque anterior" apagon_inicio "$caida"
igual "apagon: el arranque sale de btime" arranque "$arranque"
igual "termina en la fase 5" fase 5
resumen "resumen: duracion y horas del apagon" "Apagon de 7 h 46 min (04:03 -> 11:50 UTC)"
resumen "NAS que no responde: pendiente" "el NAS (127.0.0.1) no responde"
llamo "montaje fallido: se reintenta" "systemctl start descargas.mount"
resumen "montaje recuperado: hecho" "montaje $T/nas/descargas recuperado"
resumen "montaje que no vuelve: pendiente" "$T/nas/media sin montar"
no_llamo "montaje sano: no se toca" "systemctl start respaldos.mount"
resumen "arranque fallido que converge al reintentar" "yggdrasil-arranque.service convergio al reintento 1"
igual "un reintento contado" reintentados 1
resumen "arranque que sigue fallando: pendiente" "ves-market-arranque.service sigue fallando tras 3 reintentos"
no_llamo "arranque sano: no se reinicia" "systemctl restart andvari-arranque.service"
llamo "contenedor muerto en este arranque: se arranca" "docker start transmission"
no_llamo "contenedor parado antes del apagon: no se toca" "docker start manual"
no_llamo "tarea de un solo uso: no se toca" "docker start init"
resumen "contenedor que no arranca: pendiente" "contenedor roto no arranca (salio con 1)"
llamo "job que corrio antes de estar listo: se relanza" "systemctl start fafnir-catalogo.service"
no_llamo "job que no corrio en este arranque: no se relanza" "systemctl start yggdrasil-respaldo.service"
no_llamo "job que corrio despues de estar listo y bien: no se relanza" "systemctl start bragi-respaldo.service"
llamo "job que fallo despues: se relanza" "systemctl start ves-market-respaldo-nas.service"
igual "dos relanzados con exito" relanzados 2
resumen "job que falla al relanzarlo: pendiente" "hermod-respaldo.service fallo al relanzarlo"
llamo "tras un apagon, Sleipnir se reinicia para medir" "docker restart yggdrasil-throughput-probe"
resumen "alerta esperable: aparte, con su WAN" "SleipnirSinMedicion wan1"
resumen "alerta inesperada: pendiente" "alerta NasNoMontado"
if grep -q "alerta BaldrConPendientes" "$T/baldr/resumen"; then mal "las alertas de Baldr no cuentan como pendientes"; else ok "las alertas de Baldr no cuentan como pendientes"; fi
resumen "otro host con pendientes, segun Thor" "nidavellir: Baldr con pendientes o sin terminar"
resumen "unidad fallida que nadie arreglo: pendiente" "unidad unidad-vieja.service fallida"
igual "pendientes contados" pendientes 8
if grep -q "Priority: high" "$T/curl.log" && grep -q "Tras el arranque: 8 pendiente(s)" "$T/curl.log"; then
    ok "push de prioridad alta con el recuento"; else mal "push de prioridad alta con el recuento"; fi
if cmp -s "$T/push.txt" "$T/baldr/resumen"; then ok "el push lleva el resumen"; else mal "el push lleva el resumen"; fi

# --- 2. Un reinicio ordenado sin nada roto: sin push ------------------------------------------
preparar
printf '%s\n' "systemd-shutdown[1]: Sending SIGTERM to remaining processes..." "systemd-journald[1]: Journal stopped" > "$T/ultimas"
touch "$T/montado-respaldos.mount"; : > "$T/montajes-fallidos"
echo "yggdrasil-arranque.service enabled enabled" > "$T/arranques"; echo active > "$T/estado-yggdrasil-arranque.service"
: > "$T/salidos"; : > "$T/unidades-fallidas"
echo "fafnir-catalogo.service 700000000 success" > "$T/jobs"
echo '[{"labels":{"alertname":"HostReiniciado"}}]' > "$T/am.json"; echo '{"data":{"result":[]}}' > "$T/prom.json"
BALDR_MONTAJES="$T/nas/respaldos" BALDR_JOBS="fafnir-catalogo.service" BALDR_CONTENEDORES="yggdrasil-throughput-probe" \
BALDR_VERIFICAR=1 bash "$BALDR" > "$T/salida" 2>&1 || mal "baldr salio con error"
igual "reinicio ordenado: limpio" limpio 1
igual "reinicio ordenado: nada pendiente" pendientes 0
resumen "reinicio ordenado: dice cuando volvio" "Reinicio ordenado; volvio a las 11:50 UTC."
resumen "reinicio ordenado: nada pendiente en el resumen" "Nada pendiente."
no_llamo "reinicio ordenado: Sleipnir no se reinicia" "docker restart"
if [ -s "$T/curl.log" ]; then mal "reinicio ordenado sin nada roto: no hay push"; else ok "reinicio ordenado sin nada roto: no hay push"; fi

# --- 3. Revision a mano: conserva la ventana, verifica, no avisa ------------------------------
echo '[{"labels":{"alertname":"UnidadFallida","nombre":"x.service"}}]' > "$T/am.json"
: > "$T/llamadas"
BALDR_VERIFICAR=1 bash "$BALDR" verificar > "$T/salida" 2>&1 || mal "baldr verificar salio con error"
igual "verificar: conserva la ventana" limpio 1
igual "verificar: cuenta lo que hay ahora" pendientes 1
resumen "verificar: la alerta nueva, con su nombre" "alerta UnidadFallida x.service"
no_llamo "verificar: no relanza nada" "systemctl start"
if [ -s "$T/curl.log" ]; then mal "verificar: no avisa"; else ok "verificar: no avisa"; fi

# --- 4. Un host sin arranque anterior en el registro -----------------------------------------
preparar
echo '[{"boot_id":"bbb","last_entry":1}]' > "$T/boots.json"
: > "$T/arranques"; : > "$T/jobs"
bash "$BALDR" > "$T/salida" 2>&1 || mal "baldr salio con error"
igual "primer arranque registrado: nada que reconstruir" apagon_inicio 0
igual "primer arranque registrado: termina" fase 5

# --- 5. verificar sin pasada previa en este arranque: calcula la ventana, no la supone ---------
# (Baldr recien instalado el 2026-10-28: daba "Reinicio ordenado" tras un corte de 7 h)
preparar
printf '%s\n' "Starting morocota-vigia.service..." > "$T/ultimas"
: > "$T/unidades-fallidas"; echo '[]' > "$T/am.json"; echo '{"data":{"result":[]}}' > "$T/prom.json"
BALDR_VERIFICAR=1 bash "$BALDR" verificar > "$T/salida" 2>&1 || mal "baldr verificar salio con error"
igual "verificar sin estado: detecta el corte" limpio 0
igual "verificar sin estado: la caida" apagon_inicio "$caida"
if grep -q "No such file" "$T/salida"; then mal "verificar sin estado: sin errores ruidosos"; else ok "verificar sin estado: sin errores ruidosos"; fi
# un estado de un arranque anterior tampoco vale
sed -i 's/^arranque .*/arranque 1/; s/^limpio .*/limpio 1/' "$T/baldr/estado"
BALDR_VERIFICAR=1 bash "$BALDR" verificar > "$T/salida" 2>&1 || mal "baldr verificar salio con error"
igual "verificar con estado de otro arranque: lo recalcula" limpio 0

# --- 6. verificar en un host sin Mimir (nidavellir): no consulta Gjallarhorn -------------------
: > "$T/llamadas"
BALDR_VERIFICAR=0 bash "$BALDR" verificar > "$T/salida" 2>&1 || mal "baldr verificar salio con error"
no_llamo "sin BALDR_VERIFICAR: no consulta Gjallarhorn" "docker exec"
igual "sin BALDR_VERIFICAR: nada pendiente por no poder consultar" pendientes 0

# --- 7. A mano, sin el entorno de la unidad: lee /etc/default/yggdrasil-baldr ------------------
echo "BALDR_VERIFICAR=1" > "$T/conf"
echo '[{"labels":{"alertname":"NasNoMontado"}}]' > "$T/am.json"
BALDR_CONF="$T/conf" bash "$BALDR" verificar > "$T/salida" 2>&1 || mal "baldr verificar salio con error"
resumen "a mano: usa la configuracion del host" "alerta NasNoMontado"
# con la pasada automatica en marcha, verificar no toca su estado
echo active > "$T/estado-yggdrasil-baldr.service"
cp "$T/baldr/estado" "$T/estado.antes"
if BALDR_VERIFICAR=1 bash "$BALDR" verificar > "$T/salida" 2>&1; then mal "pasada en marcha: verificar se niega"; else ok "pasada en marcha: verificar se niega"; fi
if cmp -s "$T/estado.antes" "$T/baldr/estado"; then ok "pasada en marcha: el estado queda intacto"; else mal "pasada en marcha: el estado queda intacto"; fi
rm -f "$T/estado-yggdrasil-baldr.service"

# --- 8. Un disco local que monta tarde (fsck tras el corte): se espera, no es un pendiente --------
# (nidavellir, 2026-10-28 15:31: el WD monto 4 s despues de que Baldr lo diera por perdido)
preparar
mkdir -p "$T/medios/wd"; echo 3 > "$T/tarde-wd.mount"; rm -f "$T/montajes-fallidos"
: > "$T/arranques"; : > "$T/jobs"; : > "$T/salidos"; : > "$T/unidades-fallidas"
BALDR_MONTAJES="$T/medios/wd" bash "$BALDR" > "$T/salida" 2>&1 || mal "baldr salio con error"
igual "montaje que llega tarde: nada pendiente" pendientes 0
no_llamo "montaje que llega tarde sin fallar: no se reinicia" "systemctl start wd.mount"
# y uno que no llega en BALDR_ESPERA_MONTAJE_S, si
echo 99 > "$T/tarde-wd.mount"
BALDR_MONTAJES="$T/medios/wd" bash "$BALDR" > "$T/salida" 2>&1 || mal "baldr salio con error"
resumen "montaje que no llega a tiempo: pendiente con la espera" "$T/medios/wd sin montar tras 30 s"

# --- 9. Registro ilegible a tiempo: corte sin hora, sin colgarse ----------------------------------
preparar
touch "$T/registro-cuelga"
bash "$BALDR" > "$T/salida" 2>&1 || mal "baldr salio con error"
rm -f "$T/registro-cuelga"
igual "registro ilegible: se trata como corte" limpio 0
igual "registro ilegible: termina" fase 5
resumen "registro ilegible: lo dice" "no pude leer el registro del arranque anterior"
resumen "registro ilegible: sin hora de caida" "Arranque tras un corte; volvio a las 11:50 UTC, sin hora de caida."

echo
[ "$fallos" -eq 0 ] && echo "todas las pruebas pasan" || { echo "$fallos prueba(s) fallan"; exit 1; }
