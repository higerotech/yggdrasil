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
