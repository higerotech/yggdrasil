#!/usr/bin/env bash
# prueba-pia.sh — pia-tunel.sh con curl, wg, ip, nft, ping, sysctl y logger simulados. No toca la
# red. Comprueba que las credenciales, el token y la clave privada nunca van como argumento ni al
# journal, la tabla del desvio, la vuelta a directo cuando el tunel no responde y su regreso.
# Uso:  bash deploy/host/tests/prueba-pia.sh
#       NFT_REAL=1 sudo -E bash deploy/host/tests/prueba-pia.sh   (ademas, `nft -c` de la tabla real)
# Lee y reinicia el estado global de pia-tunel.sh, que ShellCheck no ve sin seguir el `source`.
# shellcheck disable=SC2034,SC2154
set -uo pipefail

AQUI=$(cd "$(dirname "$0")" && pwd)
NFT_SISTEMA=$(command -v nft || true)
T=""
trap '[ -n "$T" ] && rm -rf "$T"' EXIT
T=$(mktemp -d)
mkdir -p "$T/bin" "$T/run"

# Contrasena con todo lo que rompe un `source` o una linea de ordenes
CLAVE='p@ss "w0rd" $HOME `id` & ;x'
printf 'PIA_USER=%s\nPIA_PASS=%s\n' p1234567 "$CLAVE" > "$T/pia.env"
printf 'PIA_REGION=us_florida\nPIA_MACS=30:9C:23:E0:FB:A3\n' > "$T/pia.conf"
touch "$T/ca.crt"

cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
# Guarda la linea de ordenes (para buscar secretos en ella) y responde segun la URL.
printf '%s\n' "$*" >> "$STUB/curl-args"
url=""; for a in "$@"; do case "$a" in https://*) url=$a ;; esac; done
case "$url" in
  */api/client/v2/token)
    [ -f "$STUB/token-falla" ] && { echo '{"message":"bad"}'; exit 0; }
    # El usuario y la contrasena llegan por -F "campo=</dev/fd/N": se comprueba lo que se lee
    for a in "$@"; do
      case "$a" in username=\<*) cat "${a#username=<}" > "$STUB/usuario-leido" ;;
                   password=\<*) cat "${a#password=<}" > "$STUB/clave-leida" ;; esac
    done
    echo '{"token":"TOKEN-SECRETO-123"}' ;;
  *serverlist*)
    echo '{"regions":[{"id":"us_florida","servers":{"wg":[{"ip":"198.51.100.7","cn":"miami401"}]}}]}'
    echo 'firma' ;;
  *addKey)
    for a in "$@"; do case "$a" in pt@*) cat "${a#pt@}" > "$STUB/token-leido" ;; esac; done
    [ -f "$STUB/addkey-falla" ] && { echo '{"status":"ERROR"}'; exit 0; }
    echo '{"status":"OK","server_key":"CLAVESRV=","server_port":1337,"peer_ip":"10.20.30.40","dns_servers":["10.0.0.243"]}' ;;
esac
EOF
cat > "$T/bin/wg" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB/wg-args"
case "$1" in
  genkey) echo 'CLAVE-PRIVADA-SECRETA=' ;;
  pubkey) cat > /dev/null; echo 'CLAVE-PUBLICA=' ;;
  set) for ((i = 1; i <= $#; i++)); do
         [ "${!i}" = private-key ] && { j=$((i + 1)); cat "${!j}" > "$STUB/privada-leida"; }
       done ;;
  show) [ -f "$STUB/link-pia0" ] && printf 'CLAVESRV=\t1792000000\n' ;;
esac
exit 0
EOF
cat > "$T/bin/ip" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB/ip-args"
case "$1 $2" in
  "link show") [ -f "$STUB/link-pia0" ] ;;
  "link add")  touch "$STUB/link-pia0" ;;
  "link del")  [ -f "$STUB/link-pia0" ] && rm -f "$STUB/link-pia0" ;;
  "rule add")  p="${*: -1}"; echo "$p" >> "$STUB/reglas" ;;
  "rule del")  p="${*: -1}"; grep -qx "$p" "$STUB/reglas" 2>/dev/null || exit 2
               grep -vx "$p" "$STUB/reglas" > "$STUB/reglas.n"; mv "$STUB/reglas.n" "$STUB/reglas" ;;
  "rule show") p="${*: -1}"; grep -x "$p" "$STUB/reglas" 2>/dev/null ;;
  *) exit 0 ;;
esac
EOF
cat > "$T/bin/nft" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "-f -") cat > "$STUB/nft-tabla" ;;
  "delete table inet yggdrasil_pia") [ -f "$STUB/nft-tabla" ] && rm -f "$STUB/nft-tabla" ;;
  "list table inet yggdrasil_pia") [ -f "$STUB/nft-tabla" ] ;;
esac
EOF
cat > "$T/bin/ping" <<'EOF'
#!/usr/bin/env bash
[ -f "$STUB/ping-falla" ] && exit 1; exit 0
EOF
cat > "$T/bin/logger" <<'EOF'
#!/usr/bin/env bash
echo "${*: -1}" >> "$STUB/log"
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/sysctl"
chmod +x "$T/bin/"*
export STUB="$T" PATH="$T/bin:$PATH" PIA_CONF="$T/pia.conf" PIA_CREDENCIALES="$T/pia.env" \
    PIA_CA="$T/ca.crt" PIA_ESTADO_DIR="$T/run"
: > "$T/log"; : > "$T/reglas"

fallos=0
ok()  { echo "ok   $1"; }
mal() { echo "FALLO $1"; fallos=$((fallos + 1)); }
es()  { if [ "$2" = "$3" ]; then ok "$1"; else mal "$1 (esperado '$3', sale '$2')"; fi; }
hay() { if grep -qF -- "$3" "$2" 2>/dev/null; then ok "$1"; else mal "$1"; fi; }
no_hay() { if grep -qF -- "$3" "$2" 2>/dev/null; then mal "$1"; else ok "$1"; fi; }
estado() { awk -v k="$1" '$1 == k {print $2}' "$T/run/estado"; }

export PIA_TUNEL_SIN_BUCLE=1
# shellcheck source=../pia-tunel.sh
. "$AQUI/../pia-tunel.sh"
REINTENTO_S=0

# --- Arranque: token, clave y tunel ------------------------------------------------------
vuelta
es "la contrasena llega entera a curl por descriptor" "$(cat "$T/clave-leida" 2>/dev/null)" "$CLAVE"
es "el usuario llega por descriptor" "$(cat "$T/usuario-leido" 2>/dev/null)" p1234567
no_hay "la contrasena no aparece en la linea de ordenes de curl" "$T/curl-args" 'w0rd'
no_hay "el usuario no aparece en la linea de ordenes de curl" "$T/curl-args" 'p1234567'
es "el token llega a addKey por descriptor" "$(cat "$T/token-leido" 2>/dev/null)" TOKEN-SECRETO-123
no_hay "el token no aparece en la linea de ordenes" "$T/curl-args" 'TOKEN-SECRETO'
es "la clave privada llega a wg por descriptor" "$(cat "$T/privada-leida" 2>/dev/null)" CLAVE-PRIVADA-SECRETA=
no_hay "la clave privada no aparece en la linea de ordenes de wg" "$T/wg-args" 'CLAVE-PRIVADA-SECRETA'
hay "addKey contra el servidor de la region, con su certificado" "$T/curl-args" "--connect-to miami401::198.51.100.7: --cacert $T/ca.crt"
hay "endpoint del servidor y keepalive" "$T/wg-args" "endpoint 198.51.100.7:1337 allowed-ips 0.0.0.0/0 persistent-keepalive 25"
hay "MTU reducido" "$T/ip-args" "link set pia0 mtu 1380 up"
hay "ruta por defecto del tunel en su tabla" "$T/ip-args" "route replace default dev pia0 table 300"
for s in "$CLAVE" TOKEN-SECRETO CLAVE-PRIVADA-SECRETA p1234567; do
    no_hay "el journal no lleva '$s'" "$T/log" "$s"
done

# --- Desvio ------------------------------------------------------------------------------
es "estado: tunel arriba" "$(estado tunel)" 1
es "estado: desvio activo" "$(estado desvio)" 1
es "estado: un equipo" "$(estado equipos)" 1
es "estado: region" "$(estado region)" us_florida
es "estado: ultimo handshake" "$(estado handshake)" 1792000000
hay "la MAC entra en el set, en minusculas" "$T/nft-tabla" "elements = { 30:9c:23:e0:fb:a3 }"
hay "todo su IPv4 se marca" "$T/nft-tabla" 'ether saddr @equipos meta nfproto ipv4 meta mark set 0x10'
hay "su IPv6 hacia fuera se descarta" "$T/nft-tabla" 'meta nfproto ipv6 ip6 daddr != { fe80::/10, ff00::/8 } drop'
hay "su DNS va al de PIA" "$T/nft-tabla" 'th dport 53 dnat ip to 10.0.0.243'
hay "masquerade por pia0" "$T/nft-tabla" 'oifname "pia0" masquerade'
hay "el cambio es atomico: la tabla se declara y se borra antes" "$T/nft-tabla" 'delete table inet yggdrasil_pia'
hay "la LAN y Docker siguen en local" "$T/reglas" 87
hay "el resto, a la tabla del tunel" "$T/reglas" 88

# --- Tunel sin respuesta: vuelta a directo ----------------------------------------------
touch "$T/ping-falla"
vuelta; vuelta
es "dos sondas fallidas: el desvio sigue" "$(estado desvio)" 1
vuelta
es "tres sondas fallidas: desvio retirado" "$(estado desvio)" 0
[ -f "$T/nft-tabla" ] && mal "sin tunel no queda la tabla del desvio" || ok "sin tunel no queda la tabla del desvio"
es "sin tunel no quedan reglas" "$(wc -l < "$T/reglas" | tr -d ' ')" 0
hay "la retirada se registra" "$T/log" "desvio retirado (el tunel no responde)"
rm "$T/ping-falla"
vuelta
es "el tunel responde otra vez: desvio de vuelta" "$(estado desvio)" 1

# --- Reaplicar si alguien borra la tabla -------------------------------------------------
rm -f "$T/nft-tabla"
vuelta
[ -f "$T/nft-tabla" ] && ok "tabla borrada desde fuera: se reaplica" || mal "tabla borrada desde fuera: se reaplica"

# --- Configuracion -----------------------------------------------------------------------
printf 'PIA_MACS=30:9c:23:e0:fb:a3,no-es-mac AA:BB:CC:DD:EE:01\n' > "$T/pia.conf"
vuelta
hay "lista de MAC: valida, separada por comas o espacios" "$T/nft-tabla" "elements = { 30:9c:23:e0:fb:a3, aa:bb:cc:dd:ee:01 }"
hay "una MAC invalida se ignora y se registra" "$T/log" "'no-es-mac' no es una MAC"
es "region por defecto us_florida" "$(estado region)" us_florida
printf 'PIA_MACS=\n' > "$T/pia.conf"
vuelta
es "PIA_MACS vacia: sin desvio" "$(estado desvio)" 0
es "PIA_MACS vacia: cero equipos" "$(estado equipos)" 0

# --- Fallos de PIA -----------------------------------------------------------------------
printf 'PIA_MACS=30:9c:23:e0:fb:a3\n' > "$T/pia.conf"
limpiar; token=""; : > "$T/log"
touch "$T/addkey-falla"
vuelta
[ -f "$T/link-pia0" ] && mal "addKey rechazado: no se crea pia0" || ok "addKey rechazado: no se crea pia0"
es "addKey rechazado: sin desvio" "$(estado desvio)" 0
es "addKey rechazado: el token se descarta para pedir otro" "$token" ""
rm "$T/addkey-falla"; touch "$T/token-falla"
vuelta
hay "sin token: se registra sin mostrar nada" "$T/log" "PIA no dio token"
rm "$T/token-falla"
vuelta
es "PIA vuelve a responder: tunel y desvio" "$(estado tunel)$(estado desvio)" 11

# --- Parada ------------------------------------------------------------------------------
limpiar
[ -f "$T/link-pia0" ] && mal "parada: se borra pia0" || ok "parada: se borra pia0"
es "parada: los equipos salen directo" "$(estado desvio)" 0

# --- Tabla real: `nft -c` (solo con NFT_REAL=1 y root) -----------------------------------
if [ "${NFT_REAL:-0}" = 1 ]; then
    dns_pia=10.0.0.243
    if reglas_nft "30:9c:23:e0:fb:a3, aa:bb:cc:dd:ee:01" | "$NFT_SISTEMA" -c -f -; then
        ok "nft -c acepta la tabla del desvio"
    else
        mal "nft -c acepta la tabla del desvio"
    fi
fi

echo
[ "$fallos" -eq 0 ] && echo "todas las pruebas pasan" || { echo "$fallos prueba(s) fallan"; exit 1; }
