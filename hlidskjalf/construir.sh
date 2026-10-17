#!/usr/bin/env bash
# construir.sh — compila el APK de Hlidskjalf sin Gradle: aapt2, javac, d8, zipalign y apksigner del
# SDK de Android. Son dos clases y un icono; Gradle añadiría un wrapper binario y cientos de
# dependencias que vigilar (docs/03-implementation/cadena-suministro.md) para nada.
#
# Uso:  ANDROID_HOME=<sdk> bash hlidskjalf/construir.sh      →  hlidskjalf/build/hlidskjalf.apk
# Necesita en el SDK: platforms;android-25 y build-tools;34.0.0 (PLATAFORMA, BUILD_TOOLS), y un
# JDK 17. Firma con HLIDSKJALF_KEYSTORE o, si no se da, con la clave de depuración estándar de
# Android (~/.android/debug.keystore, se crea si falta): es una app de casa que se instala por adb,
# no va a ninguna tienda. Reinstalar exige la misma clave: compilar siempre en la misma máquina.
set -euo pipefail

VERSION_NAME=0.1.0
VERSION_CODE=1
AQUI=$(cd "$(dirname "$0")" && pwd)
SDK=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}
[ -n "$SDK" ] || { echo "construir: falta ANDROID_HOME"; exit 1; }
PLATAFORMA=${PLATAFORMA:-android-25}
BT="$SDK/build-tools/${BUILD_TOOLS:-34.0.0}"
JAR="$SDK/platforms/$PLATAFORMA/android.jar"
[ -f "$JAR" ] || { echo "construir: falta $JAR (sdkmanager \"platforms;$PLATAFORMA\")"; exit 1; }

# En Windows (Git Bash) las herramientas son .exe y .bat
herramienta() {
    local n=$1
    for c in "$BT/$n" "$BT/$n.exe" "$BT/$n.bat"; do [ -f "$c" ] && { echo "$c"; return; }; done
    echo "construir: falta $n en $BT" >&2; exit 1
}
AAPT2=$(herramienta aapt2); D8=$(herramienta d8); ZIPALIGN=$(herramienta zipalign); APKSIGNER=$(herramienta apksigner)

OUT="$AQUI/build"
rm -rf "$OUT"
mkdir -p "$OUT/gen" "$OUT/clases"

echo "== recursos"
"$AAPT2" compile --dir "$AQUI/app/res" -o "$OUT/res.zip"
"$AAPT2" link -o "$OUT/base.apk" -I "$JAR" --manifest "$AQUI/app/AndroidManifest.xml" \
    --min-sdk-version 25 --target-sdk-version 25 \
    --version-code "$VERSION_CODE" --version-name "$VERSION_NAME" \
    --java "$OUT/gen" "$OUT/res.zip"

echo "== java"
mapfile -t fuentes < <(find "$AQUI/app/java" "$OUT/gen" -name '*.java')
javac -source 8 -target 8 -bootclasspath "$JAR" -Xlint:-options -Werror -encoding UTF-8 -d "$OUT/clases" "${fuentes[@]}"

echo "== dex"
mapfile -t clases < <(find "$OUT/clases" -name '*.class')
"$D8" --release --min-api 25 --lib "$JAR" --output "$OUT" "${clases[@]}"

echo "== empaquetar y firmar"
PY=python3; "$PY" -c '' 2>/dev/null || PY=python   # en Windows suele llamarse python
"$PY" - "$OUT/base.apk" "$OUT/classes.dex" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "a", zipfile.ZIP_DEFLATED) as z:
    z.write(sys.argv[2], "classes.dex")
PY
"$ZIPALIGN" -f -p 4 "$OUT/base.apk" "$OUT/alineado.apk"

KS=${HLIDSKJALF_KEYSTORE:-$HOME/.android/debug.keystore}
if [ -z "${HLIDSKJALF_KEYSTORE:-}" ] && [ ! -f "$KS" ]; then
    mkdir -p "$(dirname "$KS")"
    keytool -genkeypair -keystore "$KS" -storepass android -alias androiddebugkey -keypass android \
        -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Android Debug,O=Android,C=US" >/dev/null
fi
"$APKSIGNER" sign --ks "$KS" --ks-pass "pass:${HLIDSKJALF_KS_PASS:-android}" --ks-key-alias "${HLIDSKJALF_KS_ALIAS:-androiddebugkey}" \
    --out "$OUT/hlidskjalf.apk" "$OUT/alineado.apk"
"$APKSIGNER" verify --min-sdk-version 25 "$OUT/hlidskjalf.apk"
rm -f "$OUT/base.apk" "$OUT/alineado.apk" "$OUT/res.zip" "$OUT/hlidskjalf.apk.idsig"
echo "listo: $OUT/hlidskjalf.apk ($VERSION_NAME, $(wc -c < "$OUT/hlidskjalf.apk") bytes)"
