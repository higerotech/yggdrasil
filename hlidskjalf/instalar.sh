#!/usr/bin/env bash
# instalar.sh — instala Hlidskjalf en la tablet conectada por adb y le da la URL del tablero.
#
# La URL, con el token en el fragmento (http://<midgard>:1880/hlidskjalf/#t=<token>), llega por la
# ENTRADA ESTÁNDAR y se escribe en los datos privados de la app con run-as: no pasa por la línea
# de órdenes de ningún proceso, ni en el PC ni en la tablet. Sin entrada se conserva la que había.
# La orden completa, que trae el token desde midgard sin imprimirlo, está en hlidskjalf/README.md.
#
#   bash hlidskjalf/instalar.sh [--inicio] < fichero-con-la-url
#   --inicio  hace de Hlidskjalf la pantalla de inicio: el botón de inicio y el arranque de la
#             tablet vuelven siempre al tablero. Se deshace en Ajustes → Aplicaciones → Pantalla
#             de inicio (cinco toques en la esquina superior izquierda abren los Ajustes).
set -euo pipefail

PAQUETE=com.higerotech.hlidskjalf
AQUI=$(cd "$(dirname "$0")" && pwd)
APK=${APK:-$AQUI/build/hlidskjalf.apk}
ADB=${ADB:-adb}
inicio=0
[ "${1:-}" = --inicio ] && inicio=1

[ -f "$APK" ] || { echo "instalar: falta $APK (bash hlidskjalf/construir.sh)"; exit 1; }

# La URL se lee ANTES de cualquier llamada a adb: `adb shell` reenvía la entrada estándar a la
# tablet y se la comería. Por eso el resto de llamadas van por adb_, con </dev/null.
url=""
if [ ! -t 0 ]; then
    IFS= read -r url || true
    case "$url" in
        '') ;;                                  # entrada vacía (</dev/null): se conserva la URL
        http://*'#t='?*|https://*'#t='?*) ;;
        *) echo "instalar: la entrada no es una URL del tablero con token (#t=...)"; exit 1 ;;
    esac
fi
adb_() { "$ADB" "$@" </dev/null; }
sin_cr() { tr -d '\r '; }

[ "$(adb_ get-state 2>/dev/null)" = device ] || { echo "instalar: no hay tablet autorizada en adb"; exit 1; }
echo "tablet: $(adb_ shell getprop ro.product.model | tr -d '\r'), Android $(adb_ shell getprop ro.build.version.release | sin_cr)"

echo "== instalar $APK"
adb_ install -r "$APK"

if [ -n "$url" ]; then
    echo "== URL del tablero: ${url%%#*} (el token no se muestra)"
    printf '%s\n' "$url" | "$ADB" shell "run-as $PAQUETE sh -c 'mkdir -p files && cat > files/url && chmod 600 files/url'"
    escritos=$(adb_ shell "run-as $PAQUETE sh -c 'wc -c < files/url'" | sin_cr)
    [ "$escritos" = $(( ${#url} + 1 )) ] || { echo "instalar: files/url tiene $escritos bytes, esperaba $(( ${#url} + 1 ))"; exit 1; }
    unset url
fi

if [ "$inicio" = 1 ]; then
    echo "== pantalla de inicio"
    adb_ shell cmd package set-home-activity "$PAQUETE/.Tablero"
fi

echo "== abrir el tablero"
adb_ shell am start -S -n "$PAQUETE/.Tablero" >/dev/null   # -S: arranque limpio, recarga la URL
echo "listo"
