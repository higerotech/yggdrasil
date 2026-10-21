# Scripts de host de midgard

Código del **router**, no del stack de Yggdrasil. No lo despliega Compose ni el receptor de
despliegue continuo: se instala con `install-host.sh` y vive en `/usr/local/sbin`.

`wan-balancer.sh` llevaba desde el principio solo en el appliance. Entra al repo el 2026-09-17,
con el arreglo que se describe abajo, para que deje de haber código de producción sin versionar.

## Por qué existe el guardián

`wan-balancer` sondea cada WAN con `ping -I <ip de la WAN>`, que entra por la regla
`from <ip> lookup wanN` y **nunca toca la tabla `main`** — por donde salen la LAN, dnsmasq y los
contenedores. Eso es correcto para medir la salud del *enlace*, pero deja un punto ciego: las dos
WAN pueden estar perfectas mientras la casa no sale a internet.

El **2026-09-12, de 06:20 a 13:25 UTC**, `main` se quedó sin ruta utilizable (dockerd:
`dial udp 1.1.1.1:53: connect: network is unreachable`). La casa estuvo **7 h sin internet**,
Heimdall reportó `hogar:up = 1` todo el rato y no se disparó ninguna alerta. Se arregló a mano con
`systemctl restart dnsmasq wan-balancer`.

## Las dos capas

**1. `wan-balancer.sh` — causa raíz.** `apply_default` solo se ejecutaba al *cambiar* de estado. Con
las dos WAN sanas el estado se quedaba en `11` y la ruta no se reaplicaba jamás, así que un `main`
roto no se reparaba nunca. Ahora cada vuelta verifica con `main_default_ok` que la ruta por defecto
corresponde al estado actual y la reaplica si no (`ip route replace` es idempotente). Solo registra
cuando de verdad repara algo.

**2. `wan-watchdog.sh` — red de seguridad.** Cubre lo que el arreglo anterior no puede: que la ruta
exista y apunte bien pero el tráfico no pase igualmente, que el propio `wan-balancer` esté colgado
(systemd lo revive si muere, no si se cuelga) y que dnsmasq deje de resolver.

| Sondeo | Cómo | Qué detecta |
|---|---|---|
| Ruta real | `ping` **sin** `-I` | que la casa no sale por `main` |
| Resolución | `dig @127.0.0.1 www.gstatic.com` | dnsmasq atascado |
| Cada WAN | `ping -I <ip>` | si el problema es del ISP, para no remediar en balde |
| Sondas de Heimdall | IP viva vs. `blackbox.yml` | que una renovación de DHCP dejó las sondas ciegas |

Decisión: `main` rota con al menos una WAN sana → reinicia `wan-balancer` y reverifica. `main` bien
pero DNS caído → reinicia `dnsmasq` y reverifica. **Las dos WAN caídas → no toca nada**: es un corte
aguas arriba y reiniciar solo mete ruido.

Guardarraíles: `flock`, reintentos antes de declarar el fallo, y un cooldown de **3 remedios por
hora** — si se supera, registra crítico y *no* actúa, para no entrar en un bucle de reinicios.

**3. Reconciliación de las sondas de Heimdall.** Las sondas de blackbox llevan la IP de cada WAN
*fija* en `blackbox.yml`, que solo se regenera al desplegar. Si DHCP le cambia la IP a una WAN entre
despliegues, sus sondas quedan atadas a una dirección que ya no existe y fallan con
`bind: Cannot assign requested address` **hasta el siguiente despliegue**. El 2026-09-17 eso mantuvo
`WanCaida{wan=wan2}` disparada **5 h 18 min siendo falso positivo**, con wan2 perfectamente sana:
`wan-balancer` siguió el cambio de IP porque la lee en vivo, pero las sondas no.

El guardián compara cada minuto la IP viva de cada WAN con la que tiene escrita `blackbox.yml` y,
si difieren, ejecuta `render.sh` como el usuario `deploy` y recarga blackbox. **Este paso corre
siempre, incluso con la ruta y el DNS perfectos**, porque ese desfase se produce exactamente en ese
escenario y la salida temprana del camino feliz nunca lo alcanzaría.

`wan-watchdog.service` corre con `ProtectSystem=strict`, así que **solo puede escribir lo que
declara `ReadWritePaths`**: los directorios `blackbox/` y `alertmanager/` del despliegue, que son
los que reescribe `render.sh`. Hasta el 2026-10-06 la unidad no los declaraba y la reconciliación
fallaba con `Read-only file system` la primera vez que hizo falta. Si `render.sh` empieza a
escribir en otro sitio, o se cambian `BLACKBOX_YML` o `RENDER_SH`, hay que ampliar esa línea;
la prueba `tests/prueba-sandbox-guardian.sh` del CI lo detecta.

El acoplamiento con Yggdrasil es deliberadamente flojo: las rutas salen por variables de entorno
(`BLACKBOX_YML`, `RENDER_SH`, `RENDER_USER`) y, si los ficheros no existen, la reconciliación se
salta en silencio. Un appliance sin Yggdrasil sigue teniendo un guardián de router perfectamente
funcional.

## Salud de cada WAN: mayoría de destinos TCP

`wan-balancer` (cada 5 s), `wan-watchdog` y Heimdall (`wan:up`) deciden igual si una WAN está
sana: **responden al menos 2 de 3 comprobaciones HTTPS reales** hechas desde la IP de esa WAN
(`https://www.gstatic.com/generate_204`, `https://1.1.1.1/cdn-cgi/trace` y `https://8.8.8.8/`),
en paralelo y con 3 s de tope cada una. Los ping ya no votan.

Por qué TCP y no ping: el 2026-10-06 wan2 respondía a los ping (paquetes pequeños) mientras TCP
estaba roto hacia parte de internet y los paquetes de 1500 B se perdían sin aviso. Con un único
destino por WAN (era 1.0.0.1 para wan2) bastaba con que el ISP perdiera ese prefijo para sacar
la WAN entera del multipath; con mayoría de ping, una WAN sin TCP habría seguido dentro.

Cuando cambia el conjunto de destinos que fallan, `wan-balancer` lo registra
(`wan2: responden 2/3 destinos; fallan: ...`): un fallo parcial del ISP queda en el journal
aunque la WAN siga dentro. `tests/prueba-quorum.sh` prueba el criterio y exige que los tres
componentes usen los mismos destinos.

## Calidad de cada WAN: ventana de pérdida (2026-10-21)

La mayoría TCP dice si una WAN **está viva**, no si **sirve**. TCP retransmite, y una comprobación
HTTPS pasa en 3 s aunque el enlace pierda muchos paquetes. Del 19 al 21 de octubre wan2 perdió un
15-30 % de los ping y solo falló el 2 % de las comprobaciones TLS. Nunca sumaba los 3 fallos
seguidos que la sacaban, así que se quedó en el multipath con la mitad de los flujos de la casa,
una llamada de Slack entre ellos. Además, cuatro veces un corte de segundos en wan1 mandó la casa
entera por wan2.

Desde entonces, en cada chequeo (cada 5 s) `wan-balancer`:

- Manda un ping a cada objetivo ICMP de Heimdall (`1.1.1.1`, `8.8.8.8` y `208.67.222.222`) y lo
  apunta en una **ventana de 24 chequeos** (2 min). Solo cuenta si ese chequeo tuvo mayoría TCP:
  un corte ya lo detectan los fallos TCP, y sus ping retrasarían la vuelta.
- Cuenta los perdidos de los **dos mejores** objetivos (48 ping): uno solo que no conteste no saca
  la WAN, igual que la mediana de `wan:perdida_pct:5m`.

| Decisión | Antes | Ahora |
|---|---|---|
| Sacar la WAN | 3 chequeos TCP seguidos sin mayoría (15 s) | 2 chequeos TCP seguidos sin mayoría (10 s) **o** ≥ 3 ping perdidos de 48 en la ventana (~6 %) |
| Devolverla | 3 chequeos TCP con mayoría (15 s) | 6 chequeos TCP con mayoría (30 s) **y** ≤ 1 perdido con la ventana llena |
| Las dos fuera | se conservaba la última ruta | la menos mala: la que responde por TCP; si responden las dos, la que pierde menos (solo se cambia si la otra pierde 2 ping menos); en un corte de las dos, la actual |

Umbrales calibrados con 7 días de sondas ICMP de Heimdall, que van al mismo ritmo de 5 s. wan1
sana tiene ≤ 1 perdido en el 99,77 % de las ventanas y ≥ 3 en el 0,18 %, cortes reales incluidos.
wan2 el 21 de octubre tenía una mediana de 8 perdidos y un mínimo de 2.

El journal dice por qué entra o sale cada WAN
(`wan2: fuera (TCP 9 ok/0 fallos seguidos, perdidos 4/48 ping en la ventana)`), y cuándo la ruta va
por la menos mala (`default: solo wan1 (las dos fuera; la menos mala: perdidos wan1 0, wan2 8)`).

Consecuencia para Heimdall: una WAN viva que pierde paquetes está fuera de la ruta aunque
`wan:up = 1`. `WanSanaFueraDeRuta` no la cuenta como discrepancia mientras tenga pérdida ≥ 1 % en
los últimos 15 min. `tests/prueba-perdida.sh` prueba la ventana, los umbrales, la WAN menos mala y
que `PERDIDA_ICMP` coincide con los objetivos de Heimdall.

Límite conocido: quitar una WAN de la ruta no mueve los flujos que ya salían por ella. Su NAT
apunta a la IP de esa WAN, así que esas conexiones se cortan y la aplicación reconecta por la otra.
Una llamada se recupera en unos segundos.

## Recorte de MSS (en `/etc/nftables.conf`, fuera de este repo)

El firewall vive en `/etc/nftables.conf` (proyecto de routing, con copia de trabajo idéntica en
`~/nftables-connmark.conf`). El 2026-10-06 se corrigió allí el recorte de MSS:

- La regla antigua estaba al **final** de `chain forward`, detrás de los `accept`: no se aplicaba
  nunca. Ahora va en cadenas propias con prioridad `mangle`, que corren antes del filtro:
  `mss_reenvio` (tráfico de la casa) y `mss_salida` (tráfico del propio host).
- wan2: **MSS fijo de 1440**. El camino del ISP2 descarta los paquetes de 1500 B sin devolver
  "fragmentation needed" (1480 pasan), y `rt mtu` no sirve porque toma el MTU de la interfaz.
  wan1 sigue con `rt mtu`.

Comprobación: `nft list chain inet router mss_reenvio` (los contadores suben) y un SYN capturado
en wan2 con `mss 1440`. Si el ISP2 cambia, volver a medir con `ping -M do -s <n> -I <ip de wan2>`.

## Relación con la alerta `HogarSinRuta`

Son complementarios y el orden importa. El guardián corre cada minuto y remedia en ~20 s;
`HogarSinRuta` (Prometheus, `for: 2m`) tarda 2 min en dispararse. En el caso normal el guardián lo
arregla **antes** de que la alerta salte, y no molesta a nadie. Si la alerta llega igualmente, es
que el remedio automático no funcionó — y eso es exactamente cuando quieres que te avisen.

## Túnel PIA (`pia-tunel`, ADR-0009)

Todo el tráfico de los equipos elegidos sale por un túnel WireGuard a Private Internet Access, abierto desde
midgard y no desde el equipo. Hoy solo está el PC de Jeremi (decisión HITL del 2026-10-21).

**Por qué en midgard y no con la app en el PC.** La app envuelve todo en un único flujo UDP. El 21 de octubre
el multipath lo puso en wan2, que perdía un 20 %, y la llamada entera viajó por ahí. Desde midgard, los
paquetes exteriores del túnel salen por la ruta por defecto que mantiene `wan-balancer`. Si la WAN cambia,
WireGuard sigue al nuevo origen y la IP de salida, la de PIA, no cambia: las conexiones del equipo no se cortan.

| Pieza | Qué hace |
|---|---|
| `pia0` | WireGuard a una región de PIA, con MTU 1380 por el agujero negro de MTU de wan2 |
| Tabla `inet yggdrasil_pia` | Propia del servicio: no toca las del router ni las de Docker |
| Marca `0x10` | Todo el IPv4 de las MAC de `PIA_MACS` |
| Regla 87 (`lookup main suppress_prefixlength 0`) | La LAN y las redes de Docker siguen en local |
| Regla 88 (`lookup 300`) | El resto de lo marcado, al túnel |
| DNAT del puerto 53 al DNS de PIA | El ISP deja de ver las consultas DNS del equipo |
| `masquerade` por `pia0` | La salida a internet lleva la IP del túnel |
| Descarte de IPv6 hacia fuera | PIA solo da IPv4 |
| Sonda a `1.1.1.1` por `pia0` cada 5 s | 3 fallos seguidos: el desvío se retira y los equipos salen directo; se rehace el túnel con una clave nueva |

No hay kill switch: sin túnel, el equipo sale directo (R4 de la ADR). Cuando el desvío entra o sale, las
conexiones abiertas se cortan una vez, porque su NAT cambia, y las aplicaciones reconectan.

**Configuración** (no está en el repositorio, que es público):

- **`/etc/yggdrasil-pia.conf`** (644):
  - `PIA_MACS`: MAC de los equipos, separadas por comas o espacios.
  - `PIA_REGION`: un `id` de `serverlist.piaservers.net/vpninfo/servers/v6`. Por defecto, `us_florida`.
- **`/etc/yggdrasil-pia.env`** (root 600): `PIA_USER` y `PIA_PASS`.
  - **Lo escribe Jeremi**, desde su terminal; Claude nunca ve la contraseña:

    ```bash
    ssh -t jalcala@192.168.10.1 'read -rp "Usuario PIA: " U; read -rsp "Contraseña PIA: " P; echo;
      sudo install -m 600 -o root -g root /dev/null /etc/yggdrasil-pia.env;
      { echo "PIA_USER=$U"; echo "PIA_PASS=$P"; } | sudo tee /etc/yggdrasil-pia.env >/dev/null; unset U P'
    ```

  - Comprobación sin revelar nada: `sudo awk -F= '{print $1, length($2)}' /etc/yggdrasil-pia.env`.
  - `pia-tunel.sh` lee el fichero sin `source`, porque la contraseña puede llevar cualquier carácter.
  - Usuario, contraseña y token llegan a curl por descriptores, y la clave privada a `wg` también: nunca van
    como argumento, que se ve con `ps`. Ni el token ni la clave se escriben en disco ni en el journal.
    `tests/prueba-pia.sh` lo comprueba.
- **Firewall:** `/etc/nftables.conf` necesita en `chain forward` la línea `iifname "lan" oifname "pia0" accept`.
  La vuelta ya la cubre `ct state established,related accept`.

**Estado y alertas.**
- `pia-tunel.sh` escribe `/run/yggdrasil-pia/estado` (túnel, desvío, equipos, último handshake y región).
- Thor lo publica como `yggdrasil_pia_*`.
- `TunelPiaSinDesvio`: hay equipos configurados, pero salen directo.
- `TunelPiaCaido`: la unidad está parada.

```bash
sudo wg show pia0                       # handshake y tráfico
journalctl -t pia-tunel -n 20           # arriba / desvío activo / retirado, y por qué
cat /run/yggdrasil-pia/estado
sudo nft list table inet yggdrasil_pia
ip rule show priority 88
```

**Quitarlo:**
- Para dejar de usarlo: `sudo systemctl disable --now pia-tunel`. Al pararse retira el desvío y borra `pia0`.
- Para sacar un solo equipo: quita su MAC de `PIA_MACS`. El servicio lo nota en la siguiente vuelta, en 5 s.

## Instalación

```bash
sudo bash deploy/host/install-host.sh          # idempotente
```

Comprobaciones:

```bash
sudo /usr/local/sbin/wan-watchdog.sh --estado    # diagnóstico, nunca remedia
sudo /usr/local/sbin/wan-watchdog.sh --dry-run   # dice qué haría, sin tocar nada
systemctl list-timers wan-watchdog.timer
journalctl -t wan-watchdog -f
```

El camino feliz **no escribe nada** en el journal: si ves una línea de `wan-watchdog`, pasó algo.
