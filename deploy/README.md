# deploy/ — Heimdall en el appliance

Artefactos ejecutables de Yggdrasil (Gate 2). Todo corre en Docker Compose sobre el appliance
(ADR-0002); ningún dato real vive aquí: IPs, token y contraseñas van en `.env` (gitignored) y
los archivos renderizados a partir de las plantillas `*.tmpl` también están ignorados.

| Ruta | Servicio | Qué es |
|---|---|---|
| `docker-compose.yml` | todos | Imágenes pineadas (ver `imagenes.md`), `mem_limit` (RNF01, 1408 MB), `restart` (RNF02), host-mode solo en sondas (ADR-0003); incluye Ratatosk y Nornas (ADR-0006) |
| `blackbox/blackbox.yml.tmpl` | Huginn y Muninn | Módulos `icmp_wan1/2` y `tls_wan1/2` con `source_ip_address` por WAN |
| `prometheus/` | Mimir | Scrape cada 15 s, recording rules y alertas del contrato |
| `alertmanager/alertmanager.yml.tmpl` | Gjallarhorn | Rutas, inhibición y webhook a Nornas con token Bearer |
| `grafana/` | Odín | Datasource y dashboard `heimdall-sla` provisionados |
| `sleipnir/` | Sleipnir | Imagen propia: throughput con la CLI de Ookla, una WAN cada 3 h, `/metrics` en :9469 |
| `mosquitto/` | Ratatosk | Mosquitto 2 (servicio de plataforma, ADR-0006): auth por cliente y ACL por tópico; passwd generado al arrancar desde `.env` |
| `nornas/settings.js`, `nornas/init/` | Nornas | Node-RED 4 (servicio de plataforma): editor autenticado; `nornas-init` importa el flujo por la Admin API con las credenciales MQTT |
| `nornas/flows/heimdall-alertas.json` | Nornas | Flujo de Heimdall; se genera con `nornas/generar-flujo.py` a partir del JavaScript revisable de `nornas/src/` |
| `scripts/render.sh`, `scripts/deploy.sh` | — | Render de plantillas y despliegue manual de contingencia |
| `docker-compose.cd.yml`, `sync/`, `cd/` | — | Despliegue continuo con el receptor de `despliegue-continuo` (ADR-0005): tareas sync, bootstrap del servidor e inventario; ver `cd/README.md` |
| `imagenes.md` | — | Digests de las imágenes pineadas (cadena de suministro) |

## Prerrequisitos del host

- Docker Engine + Compose v2. Interfaces `wan1` y `wan2` con IPv4 y reglas `ip rule from <ip>`
  del proyecto de routing: las sondas fuerzan la IP de origen y esas reglas eligen la tabla.
- ICMP sin root para blackbox: `sysctl -w net.ipv4.ping_group_range="0 2147483647"` (persistir
  en `/etc/sysctl.d/`). El contenedor además lleva `cap_add: NET_RAW`.
- nftables (segunda barrera, ADR-0003): las sondas escuchan en la IP de docker0 (`DOCKER_HOST_GW`,
  puertos 9115 y 9469). Permitir INPUT a esos puertos solo desde las redes de Docker
  (`172.16.0.0/12`) y denegarlos desde LAN/WAN. Permitir 3000 solo desde LAN y WireGuard.
- Nada externo para MQTT ni Node-RED: Ratatosk y Nornas los levanta este mismo Compose (ADR-0006).
- `deploy/` debe vivir en un directorio con permisos restringidos (p. ej. `/srv/yggdrasil`, 750):
  `alertmanager.yml` renderizado contiene el token y se deja en 0644 para que lo lea el contenedor.

## Primer despliegue

```bash
cp .env.example .env && chmod 600 .env   # rellenar
./scripts/render.sh                       # resuelve IPs de wan1/wan2 y renderiza las plantillas
docker compose build sleipnir && docker compose up -d
curl -s http://172.17.0.1:9115/probe?module=icmp_wan1\&target=1.1.1.1 | grep probe_success
docker compose exec mimir wget -qO- localhost:9090/-/ready
```

Si una WAN no tiene IPv4 en el momento del render (ISP caído, adaptador ausente), `render.sh` conserva
la última IP renderizada y avisa, para que un despliegue no falle justo cuando un enlace está fuera;
solo aborta si tampoco hay render previo. Odín queda en `http://<HOST_LAN_IP>:3000` y el editor de Nornas en `http://<HOST_LAN_IP>:1880`, ambos con
las cuentas de `.env`; `nornas-init` importa el flujo de Heimdall solo en el primer arranque. En midgard el despliegue es
continuo (`cd/README.md`); `./scripts/deploy.sh` queda como vía manual de contingencia. Si un ISP cambia la IP, ejecutar `./scripts/render.sh` (idempotente; recarga
blackbox y Alertmanager en caliente). Conviene engancharlo a `dhclient-exit-hooks.d` o
`networkd-dispatcher` para que ocurra solo.

## Validación local (equivale al SAST de Gate 2)

```bash
cp .env.example .env && WAN1_IP=192.0.2.101 WAN2_IP=192.0.2.102 ./scripts/render.sh --sin-recarga
docker compose config -q
docker run --rm -v "$PWD/prometheus:/etc/prometheus:ro" --entrypoint promtool prom/prometheus:v3.14.0 check config /etc/prometheus/prometheus.yml
docker run --rm -v "$PWD/alertmanager:/cfg:ro" --entrypoint amtool prom/alertmanager:v0.34.0 check-config /cfg/alertmanager.yml
docker run --rm -v "$PWD/blackbox:/cfg:ro" prom/blackbox-exporter:v0.28.0 --config.check --config.file=/cfg/blackbox.yml
```

La misma batería corre en GitHub Actions (`validar-configs.yml`) en cada PR que toque `deploy/`.

## Desviaciones respecto al diseño de Gate 1

- **Tercer objetivo por TCP+TLS, no HTTP 204.** El prober `http` de blackbox no permite fijar la IP
  de origen; `www.gstatic.com:443` se valida con el handshake TLS (DNS + TLS de extremo a extremo).
- **Token en cabecera `Authorization: Bearer`,** no en la URL (mejora sobre el control de T4).
- **Sleipnir mide con la CLI oficial de Ookla ligada a cada interfaz (`-I wanN`),** no con
  `speedtest-cli`: en el i3 ese cliente Python quedaba entre 76 y 188 Mbps por CPU y por el servidor que
  elegía, y la CLI de Ookla midió 939 Mbps sobre la misma WAN (TA-07). `SLEIPNIR_MODO=speedtest` e
  `iperf3` siguen disponibles; `OOKLA_SERVER_ID` admite una lista de servidores y la sonda se queda con el máximo por sentido: la
  elección automática puede caer en un servidor lento (312 Mbps frente a 941 en la misma WAN).
- **Sleipnir sirve su textfile por HTTP** (busybox httpd en :9469) en vez de pasar por
  node_exporter, que llegará con Thor. Contrato de métricas intacto.
- **Latencia desde `probe_icmp_duration_seconds{phase="rtt"}`** (RTT real) y no desde
  `probe_duration_seconds`, que incluye resolución y setup.
- **Puertos host-mode ligados a la IP de docker0,** no a 0.0.0.0: Mimir los alcanza por
  `host.docker.internal` y la LAN no los ve aunque nftables falle.
