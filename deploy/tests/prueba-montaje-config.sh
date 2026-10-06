#!/usr/bin/env bash
# prueba-montaje-config.sh — las configuraciones renderizadas se montan como DIRECTORIO.
#
# El 2026-10-06 blackbox se quedo leyendo una configuracion vieja: blackbox.yml estaba montado
# como fichero suelto, un `sed -i` lo sustituyo por un inodo nuevo y el contenedor siguio viendo
# el anterior; ningun render ni recarga posterior le llegaba, y la regla nueva de wan:up dio una
# WanCaida falsa. Esta prueba reproduce el mecanismo con blackbox real:
#   1. en el Compose, blackbox.yml y alertmanager.yml no se montan como fichero suelto;
#   2. con el directorio montado, un reemplazo atomico (fichero nuevo + mv) llega tras /-/reload;
#   3. control negativo: con el fichero montado suelto NO llega, o la prueba no prueba nada.
# Necesita docker y curl.  Uso:  bash deploy/tests/prueba-montaje-config.sh
set -uo pipefail

AQUI=$(cd "$(dirname "$0")" && pwd)
COMPOSE="$AQUI/../docker-compose.yml"
IMG=$(awk '/^  huginn-muninn:/{f=1} f && /image:/{print $2; exit}' "$COMPOSE")
T=""
limpiar() { docker rm -f prueba-montaje-dir prueba-montaje-fich >/dev/null 2>&1; [ -n "$T" ] && rm -rf "$T"; }
trap limpiar EXIT
T=$(mktemp -d)
chmod 755 "$T"

fallos=0
ok()  { echo "ok   $1"; }
mal() { echo "FALLO $1"; fallos=$((fallos + 1)); }

echo "== 1. Compose sin montajes de fichero suelto para lo renderizado"
for f in blackbox/blackbox.yml alertmanager/alertmanager.yml; do
    if grep -E "^\s*- \./$f:" "$COMPOSE" >/dev/null; then mal "$f montado como fichero suelto"; else ok "$f no se monta suelto"; fi
done
grep -qE '^\s*- \./blackbox:/etc/blackbox' "$COMPOSE" && ok "blackbox monta el directorio" || mal "blackbox monta el directorio"
grep -qE '^\s*- \./alertmanager:/etc/alertmanager' "$COMPOSE" && ok "alertmanager monta el directorio" || mal "alertmanager monta el directorio"

echo "== 2 y 3. Reemplazo atomico con blackbox real ($IMG)"
config() {  # config <modulo>
    printf 'modules:\n  %s:\n    prober: tcp\n    timeout: 2s\n' "$1"
}
config modulo_viejo > "$T/blackbox.yml"; chmod 644 "$T/blackbox.yml"

docker run -d --name prueba-montaje-dir -p 127.0.0.1:19201:9115 -v "$T:/etc/blackbox:ro" \
    "$IMG" --config.file=/etc/blackbox/blackbox.yml >/dev/null
docker run -d --name prueba-montaje-fich -p 127.0.0.1:19202:9115 -v "$T/blackbox.yml:/etc/blackbox/blackbox.yml:ro" \
    "$IMG" --config.file=/etc/blackbox/blackbox.yml >/dev/null
for p in 19201 19202; do
    for _ in $(seq 1 30); do curl -fsS -o /dev/null "http://127.0.0.1:$p/-/healthy" 2>/dev/null && break; sleep 1; done
done

# Reemplazo atomico: lo mismo que hacen sed -i, la mayoria de editores y git
config modulo_nuevo > "$T/blackbox.yml.nuevo"; chmod 644 "$T/blackbox.yml.nuevo"
mv -f "$T/blackbox.yml.nuevo" "$T/blackbox.yml"
for p in 19201 19202; do curl -fsS -o /dev/null -X POST "http://127.0.0.1:$p/-/reload" 2>/dev/null || true; done
sleep 1

dir=$(curl -fsS http://127.0.0.1:19201/config 2>/dev/null || true)
fich=$(curl -fsS http://127.0.0.1:19202/config 2>/dev/null || true)
grep -q modulo_nuevo <<<"$dir" && ok "directorio montado: la recarga ve el fichero nuevo" \
    || mal "directorio montado: la recarga ve el fichero nuevo"
if grep -q modulo_viejo <<<"$fich" && ! grep -q modulo_nuevo <<<"$fich"; then
    ok "control negativo: con el fichero montado suelto la recarga sigue en la version vieja"
else
    mal "control negativo: el fichero suelto tambien vio el cambio; la prueba no demuestra nada"
fi

echo
[ "$fallos" -eq 0 ] && echo "todas las pruebas pasan" || { echo "$fallos prueba(s) fallan"; exit 1; }
