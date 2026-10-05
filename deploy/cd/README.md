# Despliegue continuo en midgard (ADR-0005)

Cada push a `main` construye `yggdrasil-sleipnir` y `yggdrasil-sync` en GHCR con tag `sha-<7>`; el
receptor de `despliegue-continuo` recibe el `workflow_run` firmado y despliega ese SHA en
`/srv/apps/yggdrasil` con `deploy/docker-compose.cd.yml`. Las tareas `sync-host` y `sync-net`
hacen el checkout del commit, renderizan las plantillas y recargan los servicios.

## 1. Bootstrap del servidor (una vez, con sudo)

```bash
ssh jalcala@midgard
curl -fsSL https://raw.githubusercontent.com/higerotech/yggdrasil/main/deploy/cd/bootstrap-midgard.sh -o /tmp/bootstrap-midgard.sh
sudo bash /tmp/bootstrap-midgard.sh
```

Hace, de forma idempotente: `net.ipv4.ping_group_range` para ICMP sin root; clon del repo en
`/srv/apps/yggdrasil` como usuario `deploy`; `deploy/.env` con la IP LAN, la IP de docker0, una
contraseña de Grafana y un token de webhook aleatorios (0600, nunca se sobrescribe); render y
validación inicial; entrada de Yggdrasil en `/etc/cd-receiver/apps.yml` con recarga del receptor;
e imprime las reglas nftables sugeridas sin aplicarlas. Revisa después `WAN1_IF`, `WAN2_IF` y
`NORNAS_URL` en el `.env`.

## 2. nftables (proyecto de routing)

El firewall del appliance es `/etc/nftables.conf` (tabla `inet router`, `input` con política
`drop`, recarga atómica con `nft -f` que no toca las tablas de Docker). Las sondas escuchan en la
IP de docker0 (9115, 9469) y solo Mimir debe alcanzarlas; Odín (3000) es un puerto publicado por
Docker en la IP LAN y ya lo cubre la regla de `forward` "LAN y VPN hacia contenedores". La regla
aplicada en `chain input` (2026-09-05), junto a la de DNS para contenedores:

```
ip saddr $DKR_NET tcp dport { 9115, 9469 } accept
```

`ping_group_range` quedó en `/etc/sysctl.d/90-yggdrasil.conf` el mismo día.

## 3. Webhook en GitHub (desde tu equipo)

El secreto vive en `/etc/cd-receiver/receiver.env` (root). Léelo con sudo y crea el hook sin que
pase por el repo ni por un log:

```bash
SECRET=$(ssh -t jalcala@midgard "sudo grep -oP 'WEBHOOK_SECRET=\K.*' /etc/cd-receiver/receiver.env" | tr -d '\r\n')
gh api repos/higerotech/yggdrasil/hooks -X POST \
  -f name=web -F active=true -f 'events[]=workflow_run' \
  -f config[url]=https://deploy.higerotech.com/webhook \
  -f config[content_type]=json -f config[secret]="$SECRET"
unset SECRET
```

## 3b. Paquetes GHCR públicos (una vez por imagen)

Los paquetes nuevos de la organización nacen **privados** y el receptor hace `pull` anónimo, así que
el primer build publica `yggdrasil-sleipnir` y `yggdrasil-sync` pero el despliegue falla con
`error from registry: unauthorized` (ocurrió en la 0.4.0). Tras el primer build, en GitHub:
Organization → Packages → `yggdrasil-sleipnir` → Package settings → Change visibility → **Public**;
repetir para `yggdrasil-sync`. Conviene además enlazar cada paquete al repositorio (Manage
Actions access) para que futuras publicaciones hereden los permisos. Después, relanzar el build
(`gh run rerun <id>`) para que el `workflow_run` vuelva a disparar el despliegue. Comprobación:

```bash
TOK=$(curl -s 'https://ghcr.io/token?scope=repository:higerotech/yggdrasil-sync:pull' | jq -r .token)
curl -s -o /dev/null -w '%{http_code}
' -H "Authorization: Bearer $TOK" https://ghcr.io/v2/higerotech/yggdrasil-sync/manifests/latest   # 200 = público
```

## 4. Primer despliegue y operación

**Desfase del Compose.** El receptor ejecuta `up -d` con el `docker-compose*.yml` del checkout anterior,
porque `sync-host` actualiza el clon durante ese mismo despliegue. Por eso los cambios en el Compose
(montajes, variables, servicios) se aplican un despliegue después. El workflow `build` lo compensa: si
el commit cambia el Compose, se relanza a sí mismo (`workflow_dispatch`) y el receptor despliega una
segunda vez con el Compose nuevo. Los cambios en ficheros de configuración no sufren el desfase.

El primer arranque de Odín migra su base SQLite y en el HDD de midgard tarda unos 3 min antes de
escuchar; por eso `health_timeout` es 300 s. Los despliegues siguientes responden en segundos. Si el
receptor marca `healthcheck agotado` con todos los contenedores `Up`, no es un fallo del stack.

El primer push a `main` que incluya este directorio dispara el workflow `build`; al terminar, el
receptor despliega. Comprobar:

```bash
curl -s http://127.0.0.1:9000/status | jq '.apps.yggdrasil'
journalctl -u cd-receiver -n 50 --no-pager
docker logs yggdrasil-sync-host --tail 20 && docker logs yggdrasil-sync-net --tail 5
docker compose -f /srv/apps/yggdrasil/deploy/docker-compose.cd.yml -p yggdrasil ps
```

Rollback manual: el receptor guarda el tag anterior; también vale volver a lanzar el workflow del
commit bueno. Contingencia sin receptor: `deploy/scripts/deploy.sh` (con `IMAGE_TAG` de un SHA ya
publicado, o `docker compose build` para construir en local).

## Pendientes conocidos
- Ratatosk y Nornas son servicios del propio Compose desde ADR-0006; el bootstrap completa en `.env`
  las credenciales MQTT y del editor si faltan. Conectar la salida push del flujo sigue siendo manual.
- El resultado de `sync-host`/`sync-net` no forma parte del healthcheck del receptor; revisar sus
  logs en el primer despliegue.

## Arranque del appliance

`bootstrap-midgard.sh` instala y habilita `yggdrasil-arranque.service`, que tras cada arranque
ejecuta `docker compose -f docker-compose.yml -p yggdrasil up -d --no-build` con la etiqueta que
el receptor tiene registrada en `/var/lib/cd-receiver/yggdrasil.json`.

Hace falta porque Docker no reaplica `restart: unless-stopped` a un contenedor que quedó en estado
`exited` durante un apagado sucio: en el reinicio del 2026-09-08 Gjallarhorn no volvió y el sistema
de alertas quedó caído en silencio. La unidad usa el Compose base a propósito, para no ejecutar en
el arranque los servicios de un solo uso `sync-host` y `sync-net`, que necesitan red hacia GitHub.

Comprobación: `systemctl is-enabled yggdrasil-arranque` y, tras un reinicio,
`systemctl status yggdrasil-arranque` más `docker compose -p yggdrasil ps`.

## Respaldo nocturno

`bootstrap-midgard.sh` instala `yggdrasil-respaldar.sh` y `yggdrasil-respaldo.timer`. Cada noche,
a las 22:30 hora de la casa (02:30 UTC, `Persistent=true` por los apagones), deja en el NAS
`/mnt/nas/respaldos/yggdrasil/yggdrasil-<UTC>.tar.gz`, con su `.sha256`, y conserva los **14** más
recientes. El volumen ronda los 225 MB.

| Contenido del archivo | Origen |
|---|---|
| `volumenes/<volumen>.tar` | los seis volúmenes `yggdrasil_*` |
| `despliegue.tar` | `/srv/apps/yggdrasil/deploy`, **con `.env` y la configuración renderizada** |
| `yggdrasil.json` | etiqueta desplegada según el receptor |
| `host/host.tar` | nftables, sysctl, netplan, `apps.yml` y las unidades y scripts de WAN y Yggdrasil |

Mimir y Odin se congelan con `docker pause` unos 5 s mientras se copian a disco local, para que la
TSDB y la SQLite queden consistentes. Ratatosk y Nornas se copian en caliente: congelarlos marca su
healthcheck como `unhealthy` durante varios minutos. La copia en el NAS se verifica contra la suma, y
la retención no borra nada si la subida del día no está verificada. El último éxito queda en
`/var/lib/yggdrasil-respaldo/ultimo-exito` (epoch).

El archivo lleva secretos. El NAS fuerza el propietario de todo lo que se escribe, así que la
protección es el modo (directorio 700, ficheros 600) y que el export `respaldos` solo admite a
midgard.

Comprobación: `systemctl list-timers yggdrasil-respaldo.timer` y
`journalctl -u yggdrasil-respaldo -n 20`. A mano: `sudo systemctl start yggdrasil-respaldo`.

### Avisos por ntfy

`yggdrasil-respaldo-aviso.sh` manda dos avisos al tema de ntfy de la casa:

| Aviso | Cuándo | Qué lo dispara |
|---|---|---|
| **Respaldo Yggdrasil FALLO** | en el momento | `OnFailure=yggdrasil-respaldo-fallo.service` del respaldo |
| **Respaldo Yggdrasil atrasado** | 08:00 hora de la casa | `yggdrasil-respaldo-vigia.timer`, si el último éxito tiene más de 26 h |

El vigía cubre lo que `OnFailure` no ve: un temporizador que no llega a dispararse o un respaldo
que nunca termina. Si anoche falló, por la mañana llegan los dos: el segundo es el recordatorio.

Van **directos del host a ntfy**, como `smartd-ntfy`, y no por Gjallarhorn → Nornas: la salida push
de Nornas sigue sin conectar, y el aviso de un respaldo no debe depender del stack que respalda.

El tema de ntfy **es** la credencial: quien lo conozca lee los avisos. Se lee de
`/etc/yggdrasil-aviso.env` (`AVISO_URL=...`), que en midgard es un enlace a `/etc/smartd-aviso.env`,
así que al rotar el tema solo hay que tocar un fichero. `bootstrap-midgard.sh` crea el enlace si
existe el de smartd.

Comprobación del canal: `sudo /usr/local/sbin/yggdrasil-respaldo-aviso.sh prueba`.

Restauración, con el stack parado (`docker compose -p yggdrasil stop`):

```bash
tar -xzf yggdrasil-<UTC>.tar.gz          # deja r/
tar -C /var/lib/docker/volumes/yggdrasil_mimir-datos/_data --numeric-owner -xpf r/volumenes/mimir-datos.tar
# ...igual con cada volumen; despliegue.tar va en /srv/apps/yggdrasil
```
