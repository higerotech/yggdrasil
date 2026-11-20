#!/usr/bin/env bash
# prueba-gna.sh — Gná de punta a punta con el gna.yml real y un Loki con la configuración real (ADR-0013).
#
# Comprueba las dos garantías de Gná:
#   1. Solo los logs de Hive y de su plataforma llegan a Loki: hive-prueba y andvari-openbao sí, otro-prueba no.
#   2. gna-docker solo deja leer: lista, inspección y logs de contenedores sí; /archive, /export, POST, /info y
#      /images no. Y solo a quien está en -allowfrom: «intruso», en la misma red, no pasa ni con lo permitido.
#
# Necesita Docker. Uso: bash deploy/nidavellir/tests/prueba-gna.sh
set -euo pipefail

DIR=$(cd "$(dirname "$0")/.." && pwd)
# En Git Bash, docker compose es un programa de Windows y no entiende /c/... ni /tmp: se le pasan rutas de Windows.
ruta() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
DIR=$(ruta "$DIR")
PROYECTO=prueba-gna
LOKI=http://127.0.0.1:13100
TMP=$(mktemp -d)
export MSYS_NO_PATHCONV=1                # Git Bash en Windows: no convertir las rutas de los contenedores
DOCKER_GID=983                           # nidavellir; se cambia por el del socket de esta máquina
GNA_YML=/dev/null                        # la copia de gna.yml, que se crea abajo

compose() {
    DOCKER_GID="$DOCKER_GID" LOKI_MIDGARD=loki docker compose -p "$PROYECTO" --project-directory "$DIR" \
        -f "$GNA_YML" -f "$DIR/tests/gna-prueba.yml" "$@"
}

# El trap va antes de crear nada
trap 'compose down -v --remove-orphans >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT

# El gna.yml real, con un único cambio: el proxy también atiende al cliente de la prueba.
grep -c -- '"-allowfrom=gna"' "$DIR/gna.yml" | grep -qx 1 || { echo "FALLO: gna.yml ya no tiene -allowfrom=gna"; exit 1; }
sed 's/"-allowfrom=gna"/"-allowfrom=gna,cliente"/' "$DIR/gna.yml" > "$TMP/gna.yml"
GNA_YML=$(ruta "$TMP/gna.yml")
DOCKER_GID=$(docker run --rm -v /var/run/docker.sock:/var/run/docker.sock:ro \
    alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce stat -c %g /var/run/docker.sock)

compose up -d --quiet-pull >/dev/null 2>"$TMP/up.err" || { cat "$TMP/up.err"; exit 1; }

valores() { curl -s "$LOKI/loki/api/v1/label/contenedor/values" || true; }

echo "== 1. Loki recibe los logs de Hive y de su plataforma, y nada más"
llegaron=""
for _ in $(seq 1 36); do
    v=$(valores)
    if grep -q '"hive-prueba"' <<<"$v" && grep -q '"andvari-openbao"' <<<"$v"; then llegaron=1; break; fi
    sleep 5
done
[ -n "$llegaron" ] || {
    echo "FALLO: en 3 min no llegaron hive-prueba y andvari-openbao. Etiquetas: $(valores)"
    docker logs yggdrasil-gna 2>&1 | tail -n 5
    exit 1
}
# otro-prueba lleva escribiendo lo mismo que los otros: si Gná lo dejara pasar, ya estaría.
sleep 10
if grep -q '"otro-prueba"' <<<"$(valores)"; then
    echo "FALLO: Gná llevó a Loki un contenedor que no es de Hive (otro-prueba)"; exit 1
fi
etiquetas=$(curl -s "$LOKI/loki/api/v1/labels" || true)
for e in host contenedor; do
    grep -q "\"$e\"" <<<"$etiquetas" || { echo "FALLO: falta la etiqueta $e: $etiquetas"; exit 1; }
done
curl -s -G "$LOKI/loki/api/v1/query_range" --data-urlencode 'query={host="nidavellir",contenedor="hive-prueba"}' \
    --data-urlencode 'limit=5' > "$TMP/q.json"
grep -q 'WARNING \[hive\] linea' "$TMP/q.json" || { echo "FALLO: no están las líneas de hive-prueba"; exit 1; }
echo "ok: llegan hive-prueba y andvari-openbao, con host=nidavellir; otro-prueba no"

echo "== 2. El proxy solo deja leer, y solo a quien está en -allowfrom"
ID=$(docker inspect -f '{{.Id}}' otro-prueba)
# Código HTTP de una petición desde un contenedor de la red interna (busybox wget: la primera línea de cabeceras).
# <contenedor> es el servicio (cliente o intruso), que es el nombre que ve el proxy.
codigo() {  # codigo <contenedor> <método> <ruta>
    local datos=()
    [ "$2" = POST ] && datos=(--post-data=)
    docker exec "prueba-gna-$1" wget -S -q -O /dev/null "${datos[@]}" "http://gna-docker:2375$3" 2>&1 \
        | awk '/HTTP\//{print $2; exit}' || true
}
espera() {  # espera <contenedor> <método> <ruta> <código>
    local c
    c=$(codigo "$1" "$2" "$3")
    [ "$c" = "$4" ] || { echo "FALLO: $1 $2 $3 dio ${c:-nada}, se esperaba $4"; exit 1; }
    echo "   $1 $2 $3 -> $c"
}
espera cliente GET /_ping 200
espera cliente GET /v1.41/containers/json 200
espera cliente GET /v1.41/networks 200
espera cliente GET "/v1.41/containers/$ID/json" 200
espera cliente GET "/v1.41/containers/$ID/logs?stdout=1&tail=1" 200
espera cliente GET "/v1.41/containers/$ID/archive?path=/etc/hostname" 403
espera cliente GET "/v1.41/containers/$ID/export" 403
espera cliente GET /v1.41/info 403
espera cliente GET /v1.41/images/json 403
espera cliente POST "/v1.41/containers/$ID/stop" 405
espera intruso GET /v1.41/containers/json 403
[ "$(docker inspect -f '{{.State.Running}}' otro-prueba)" = true ] \
    || { echo "FALLO: otro-prueba se paró: el POST pasó"; exit 1; }
echo "ok: gna-docker solo deja listar, inspeccionar y leer logs, y solo a gna"
