#!/usr/bin/env bash
# vista-previa.sh — prueba el tablero en desarrollo en la tablet real, sin desplegar.
#
# La tablet carga la página de vista-previa.py (en el PC) por `adb reverse`, con el escenario que
# se elija, y el medidor de la página dice qué no se ve entero. Antes de tocar nada se guarda la URL
# de producción (files/url, que lleva el token) en files/url.orig, con run-as y sin imprimirla.
#
#   python3 hlidskjalf/vista-previa.py &                 # en otra terminal
#   bash hlidskjalf/vista-previa.sh abrir                # la tablet pasa a la vista previa
#   bash hlidskjalf/vista-previa.sh probar hlidskjalf/escenarios/estres.json
#   bash hlidskjalf/vista-previa.sh cerrar               # vuelve la URL de producción
#
# `probar` recarga la tablet con el escenario, espera la medida, guarda una captura en
# hlidskjalf/build/vista-previa/ y sale con 1 si algo queda recortado, tapado o fuera de la pantalla.
# Después de `cerrar`, la tablet vuelve al tablero de midgard.
set -euo pipefail

PAQUETE=com.higerotech.hlidskjalf
AQUI=$(cd "$(dirname "$0")" && pwd)
TRABAJO=$AQUI/build/vista-previa
PUERTO=${PUERTO:-8099}
ADB=${ADB:-adb}
adb_() { "$ADB" "$@" </dev/null; }   # `adb shell` se come la entrada estándar
sin_cr() { tr -d '\r '; }
reiniciar() { adb_ shell am start -S -n "$PAQUETE/.Tablero" >/dev/null; }   # sin -S no relee files/url
# La ruta del escenario la lee Python: en Git Bash, Python de Windows no entiende /c/...
ruta() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else printf '%s\n' "$1"; fi; }

[ "$(adb_ get-state 2>/dev/null)" = device ] || { echo "vista-previa: no hay tablet autorizada en adb"; exit 1; }

case "${1:-}" in
abrir)
    curl -sf -o /dev/null "http://127.0.0.1:$PUERTO/hlidskjalf/" || { echo "vista-previa: arranca antes python3 hlidskjalf/vista-previa.py"; exit 1; }
    # Una sola copia: si ya hay url.orig, la vista previa ya estaba abierta y files/url no es la buena
    adb_ shell "run-as $PAQUETE sh -c 'test -f files/url.orig || cp files/url files/url.orig'"
    adb_ reverse "tcp:$PUERTO" "tcp:$PUERTO" >/dev/null
    printf '%s\n' "http://127.0.0.1:$PUERTO/hlidskjalf/#t=vista-previa" | "$ADB" shell "run-as $PAQUETE sh -c 'cat > files/url'"
    mkdir -p "$TRABAJO"
    [ -f "$TRABAJO/escenario" ] || ruta "$AQUI/escenarios/normal.json" > "$TRABAJO/escenario"
    reiniciar
    echo "tablet en la vista previa (escenario: $(basename "$(cat "$TRABAJO/escenario")")); para volver: $0 cerrar"
    ;;
probar)
    fichero=${2:?uso: $0 probar <escenario.json> [captura.png]}
    [ -f "$fichero" ] || { echo "vista-previa: no existe $fichero"; exit 1; }
    adb_ shell "run-as $PAQUETE test -f files/url.orig" || { echo "vista-previa: falta $0 abrir"; exit 1; }
    mkdir -p "$TRABAJO"
    ruta "$(cd "$(dirname "$fichero")" && pwd)/$(basename "$fichero")" > "$TRABAJO/escenario"
    rm -f "$TRABAJO/medidas.jsonl"
    reiniciar
    for _ in $(seq 1 30); do [ -s "$TRABAJO/medidas.jsonl" ] && break; sleep 1; done
    [ -s "$TRABAJO/medidas.jsonl" ] || { echo "vista-previa: la tablet no mandó la medida en 30 s"; exit 1; }
    captura=$TRABAJO/${3:-$(basename "$fichero" .json).png}
    adb_ exec-out screencap -p > "$captura"
    echo "captura: $captura"
    python3 "$AQUI/vista-previa.py" --informe
    ;;
cerrar)
    if adb_ shell "run-as $PAQUETE test -f files/url.orig"; then
        adb_ shell "run-as $PAQUETE sh -c 'cp files/url.orig files/url && chmod 600 files/url'"
        a=$(adb_ shell "run-as $PAQUETE sha256sum files/url" | cut -c1-64)
        b=$(adb_ shell "run-as $PAQUETE sha256sum files/url.orig" | cut -c1-64)
        [ "$a" = "$b" ] || { echo "vista-previa: files/url no quedó igual que la copia; url.orig se conserva"; exit 1; }
        adb_ shell "run-as $PAQUETE rm files/url.orig"
    else
        echo "vista-previa: no había vista previa abierta (sin files/url.orig); la URL no se toca"
    fi
    adb_ reverse --remove "tcp:$PUERTO" 2>/dev/null || true
    reiniciar
    echo "tablet de vuelta en $(adb_ shell "run-as $PAQUETE cat files/url" | sin_cr | sed 's/#.*//')"
    ;;
*)
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
