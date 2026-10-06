#!/usr/bin/env bash
# prueba-vigia-servicios.sh — pruebas de yggdrasil-vigia-servicios.sh con docker, systemctl,
# curl y hostname simulados en el PATH. No toca nada real. Necesita bash y jq.
# Uso:  bash deploy/cd/tests/prueba-vigia-servicios.sh
set -euo pipefail

AQUI=$(cd "$(dirname "$0")" && pwd)
VIGIA="$AQUI/../yggdrasil-vigia-servicios.sh"
T=""
trap '[ -n "$T" ] && rm -rf "$T"' EXIT
T=$(mktemp -d)
mkdir -p "$T/bin" "$T/c" "$T/u" "$T/estado"

# --- Simuladores --------------------------------------------------------------------------
cat > "$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = compose ]; then [ -f "$STUB/compose-falla" ] && exit 1; cat "$STUB/compose.json"; exit 0; fi
if [ "$1" = inspect ]; then n="${*: -1}"; [ -f "$STUB/c/$n" ] || exit 1; cat "$STUB/c/$n"; exit 0; fi
exit 2
EOF
cat > "$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  is-active) s=$(cat "$STUB/u/$2" 2>/dev/null || echo inactive); echo "$s"; [ "$s" = active ] ;;
  list-unit-files) n="${*: -1}"; [ -f "$STUB/u/$n" ] && echo "$n enabled"; exit 0 ;;
esac
EOF
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
[ -f "$STUB/curl-falla" ] && exit 7
titulo=""; datos=""
while [ $# -gt 0 ]; do
  case "$1" in -H) case "$2" in Title:*) titulo="${2#Title: }";; esac; shift 2;; -d) datos="$2"; shift 2;; *) shift;; esac
done
printf '%s|%s\n' "$titulo" "$(printf '%s' "$datos" | tr '\n' ' ')" >> "$STUB/pushes"
EOF
printf '#!/bin/sh\necho midgard\n' > "$T/bin/hostname"
chmod +x "$T/bin/"*

printf 'AVISO_URL=https://ntfy.example/tema-prueba\n' > "$T/aviso.env"
cat > "$T/compose.json" <<'EOF'
{"services": {
  "mimir":       {"container_name": "yggdrasil-prometheus", "restart": "unless-stopped"},
  "nornas":      {"container_name": "yggdrasil-node-red",   "restart": "unless-stopped"},
  "nornas-init": {"container_name": "yggdrasil-node-red-init", "restart": "no"}
}}
EOF
echo "running -"       > "$T/c/yggdrasil-prometheus"
echo "running healthy" > "$T/c/yggdrasil-node-red"
echo "exited -"        > "$T/c/yggdrasil-node-red-init"
echo active > "$T/u/docker.service"
echo active > "$T/u/wan-balancer.service"

export STUB="$T" PATH="$T/bin:$PATH" AVISO_ENV="$T/aviso.env" VIGIA_ESTADO="$T/estado" \
       VIGIA_COMPOSE="$T/compose.yml" VIGIA_UPTIME_S=99999 VIGIA_AHORA=1000000 \
       VIGIA_UNIDADES="docker.service wan-balancer.service unidad-que-no-existe.service"

pasada() { bash "$VIGIA" >/dev/null; }
n_pushes() { [ -f "$T/pushes" ] && wc -l < "$T/pushes" | tr -d ' ' || echo 0; }
ultimo() { tail -n 1 "$T/pushes"; }
fallos=0
comprobar() {  # comprobar <descripcion> <condicion...>
    local d="$1"; shift
    if "$@"; then echo "ok   $d"; else echo "FALLO $d"; fallos=$((fallos + 1)); fi
}
contiene() { grep -q -- "$1" <<<"$2"; }

pasada
comprobar "todo sano: ningun push (y la tarea de un solo uso 'exited' no cuenta)" [ "$(n_pushes)" = 0 ]

echo "running unhealthy" > "$T/c/yggdrasil-node-red"
pasada
comprobar "primer fallo: aun no avisa (umbral 2)" [ "$(n_pushes)" = 0 ]
pasada
comprobar "segundo fallo: un push" [ "$(n_pushes)" = 1 ]
comprobar "el push nombra el contenedor y el motivo" contiene "yggdrasil-node-red: unhealthy" "$(ultimo)"
comprobar "titulo con el host" contiene "midgard - Servicio caido" "$(ultimo)"
pasada
comprobar "sigue caido: no repite antes de 6 h" [ "$(n_pushes)" = 1 ]
VIGIA_AHORA=$((1000000 + 6 * 3600)) pasada
comprobar "a las 6 h: recordatorio" contiene "Siguen caidos" "$(ultimo)"

echo "running healthy" > "$T/c/yggdrasil-node-red"
VIGIA_AHORA=$((1000000 + 6 * 3600 + 60)) pasada
comprobar "al volver: aviso de recuperacion" contiene "Servicio recuperado" "$(ultimo)"
n=$(n_pushes); pasada
comprobar "despues de recuperar: silencio" [ "$(n_pushes)" = "$n" ]

rm "$T/c/yggdrasil-prometheus"
echo inactive > "$T/u/wan-balancer.service"
pasada; pasada
comprobar "dos caidos en la misma pasada: un solo push" [ "$(n_pushes)" = $((n + 1)) ]
comprobar "contenedor inexistente: 'no existe'" contiene "yggdrasil-prometheus: no existe" "$(ultimo)"
comprobar "unidad inactiva incluida" contiene "wan-balancer.service: inactive" "$(ultimo)"
comprobar "titulo en plural" contiene "Servicios caidos" "$(ultimo)"
echo "running -" > "$T/c/yggdrasil-prometheus"; echo active > "$T/u/wan-balancer.service"; pasada

echo "paused -" > "$T/c/yggdrasil-prometheus"
n=$(n_pushes); pasada; pasada
comprobar "paused (respaldo) cuenta como en marcha" [ "$(n_pushes)" = "$n" ]
echo "running -" > "$T/c/yggdrasil-prometheus"

echo failed > "$T/u/docker.service"
rm "$T/c/yggdrasil-prometheus"
n=$(n_pushes); pasada; pasada
comprobar "docker caido: avisa de docker y no de cada contenedor" \
    bash -c "grep -q 'docker.service: failed' <<<'$(ultimo)' && ! grep -q 'yggdrasil-prometheus' <<<'$(ultimo)'"
echo active > "$T/u/docker.service"; echo "running -" > "$T/c/yggdrasil-prometheus"; pasada

touch "$T/compose-falla"
echo "exited -" > "$T/c/yggdrasil-prometheus"
n=$(n_pushes); pasada; pasada
comprobar "sin poder leer el Compose: usa el inventario anterior" contiene "yggdrasil-prometheus: exited" "$(ultimo)"
rm "$T/compose-falla"; echo "running -" > "$T/c/yggdrasil-prometheus"; pasada

echo "running unhealthy" > "$T/c/yggdrasil-node-red"
touch "$T/curl-falla"
n=$(n_pushes); pasada; pasada
comprobar "push fallido: no se registra" [ "$(n_pushes)" = "$n" ]
rm "$T/curl-falla"; pasada
comprobar "push fallido: se reintenta en la siguiente pasada" contiene "yggdrasil-node-red: unhealthy" "$(ultimo)"
echo "running healthy" > "$T/c/yggdrasil-node-red"; pasada

rm -rf "$T/estado"/*
echo "exited -" > "$T/c/yggdrasil-prometheus"
n=$(n_pushes)
VIGIA_UPTIME_S=120 pasada; VIGIA_UPTIME_S=180 pasada
comprobar "arranque reciente: no comprueba" [ "$(n_pushes)" = "$n" ]

rm -rf "$T/estado"/* "$T/estado/.inventario"
echo "running -" > "$T/c/yggdrasil-prometheus"
touch "$T/compose-falla"
n=$(n_pushes); pasada; pasada
comprobar "sin Compose ni inventario anterior: avisa en vez de no vigilar nada" \
    contiene "inventario de contenedores: no puedo leer" "$(ultimo)"
rm "$T/compose-falla"; pasada
comprobar "inventario recuperado: aviso de vuelta" contiene "inventario de contenedores" "$(ultimo)"

comprobar "el tema de ntfy no aparece en ningun push" bash -c "! grep -q tema-prueba '$T/pushes'"

echo
[ "$fallos" -eq 0 ] && echo "todas las pruebas pasan" || { echo "$fallos prueba(s) fallan"; exit 1; }
