#!/usr/bin/env bash
# Medicion para ADR-0009: latencia y perdida desde cada WAN hacia regiones de PIA y destinos de
# llamadas. Solo lectura: ping y conexiones TCP con origen fijado a la IP de cada WAN.
# Uso en midgard: bash deploy/host/medir-tuneles.sh   (no toca rutas ni reglas; ~10 s)
set -u
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
ip1=$(ip -4 -o addr show dev wan1 | awk '{print $4}' | cut -d/ -f1)
ip2=$(ip -4 -o addr show dev wan2 | awk '{print $4}' | cut -d/ -f1)

curl -s -m 20 https://serverlist.piaservers.net/vpninfo/servers/v6 | head -1 > "$T/lista.json"
declare -a dest=()
for r in us_florida us_atlanta bogota mexico panama venezuela; do
    s=$(jq -r --arg r "$r" '.regions[] | select(.id == $r) | .servers.wg[0] | "\(.ip)"' "$T/lista.json")
    [ -n "$s" ] && [ "$s" != null ] && dest+=("pia-$r=$s")
done
chime=$(getent ahostsv4 app.chime.aws | awk 'NR==1 {print $1}')
[ -n "$chime" ] && dest+=("chime-app=$chime")
dest+=("llamada-21oct=102.129.153.49" "cloudflare=1.1.1.1")

medir() {  # medir <wan> <ip origen> <nombre> <ip destino>
    local p tcp
    p=$(ping -n -q -c 30 -i 0.2 -W 2 -I "$2" "$4" 2>/dev/null | awk -F'[ /,%]+' '/packet loss/ {for (i=1;i<=NF;i++) if ($i=="packet") l=$(i-1)} /rtt/ {print l, $7, $8, $9, $10}')
    tcp=$(curl -s -o /dev/null -m 5 --interface "$2" -w '%{time_connect}' "https://$4:1337/" -k 2>/dev/null || true)
    echo "$1 $3 $4 ping:${p:-sin-respuesta} tcp1337:${tcp:-x}"
}
for d in "${dest[@]}"; do
    n=${d%%=*}; a=${d#*=}
    medir wan1 "$ip1" "$n" "$a" > "$T/w1-$n" &
    medir wan2 "$ip2" "$n" "$a" > "$T/w2-$n" &
done
wait
echo "# wan perdida% min avg max mdev (ms)"
cat "$T"/w1-* "$T"/w2-* | sort
