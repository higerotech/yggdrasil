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

Decisión: `main` rota con al menos una WAN sana → reinicia `wan-balancer` y reverifica. `main` bien
pero DNS caído → reinicia `dnsmasq` y reverifica. **Las dos WAN caídas → no toca nada**: es un corte
aguas arriba y reiniciar solo mete ruido.

Guardarraíles: `flock`, reintentos antes de declarar el fallo, y un cooldown de **3 remedios por
hora** — si se supera, registra crítico y *no* actúa, para no entrar en un bucle de reinicios.

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
