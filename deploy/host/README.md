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
