# ADR-0005: Despliegue continuo con el receptor de higerotech/despliegue-continuo

* **Estado:** accepted
* **Fecha:** 2026-09-05
* **Decisores:** Jeremi
* **Fase AI-DLC:** 05-deployment
* **Versión:** 1.0.0
* **ID:** ADR-0005
* **Supersede / Superseded-by:** supersede la sección "CD" de ADR-0002 (despliegue manual con `git pull && docker compose up -d`)
* **Controles OWASP afectados:** A03 (supply chain: imágenes por SHA), A05 (configuración: receptor sin grupo docker, socket-proxy), A08 (integridad: webhook firmado HMAC)

## Contexto
ADR-0002 dejó el despliegue como `git pull && docker compose up -d` manual porque no había runner
expuesto ni se justificaba un pipeline push hacia la red doméstica. Desde entonces la organización
tiene `higerotech/despliegue-continuo` instalado y sano en el appliance (midgard): un receptor en
`127.0.0.1:9000` publicado por Cloudflare Tunnel en `deploy.higerotech.com`, que valida la firma
HMAC del evento `workflow_run`, hace `docker compose pull` y `up -d` con `IMAGE_TAG=sha-<7>` en el
directorio de la app, comprueba una `health_url` y hace rollback al tag anterior si falla. Su modelo
es de imágenes inmutables: no hace `git pull`, no construye y no ejecuta scripts arbitrarios.

Yggdrasil, en cambio, es sobre todo configuración (reglas, plantillas, dashboard) que vive en el
repo y cambia con cada release, más una imagen propia (Sleipnir). Hacía falta un puente entre ambos
modelos sin renunciar a la reproducibilidad por SHA ni al rollback.

## Decisión
Adoptar el receptor de `despliegue-continuo` como mecanismo de despliegue de Yggdrasil:
- **Build en GitHub Actions** (`build-and-push.yml`, workflow `build`) publica en GHCR
  `yggdrasil-sleipnir` y `yggdrasil-sync` con tag `sha-<7>` en cada push a `main`. Al terminar, el
  `workflow_run` firmado llega al receptor, que despliega ese SHA.
- **Los ficheros de configuración llegan por una tarea de sincronización**, no por `git pull`
  externo: `docker-compose.cd.yml` incluye el compose base y añade dos servicios de un solo uso de la
  imagen `yggdrasil-sync`. `sync-host` (host-mode, usuario `deploy`) hace checkout del commit
  `IMAGE_TAG` en el clon `/srv/apps/yggdrasil`, renderiza las plantillas con las IPs actuales de
  wan1/wan2 y recarga blackbox; `sync-net` (red interna) recarga Mimir y Gjallarhorn por HTTP.
  Sleipnir cambia de imagen con el SHA; Grafana recarga dashboards por su proveedor de archivos.
- **Rollback** = el receptor vuelve a levantar el SHA anterior: `sync-host` hace checkout de ese
  commit y las configuraciones vuelven con él.
- **`health_url`** = `http://<IP LAN>:3000/api/health` (Odín), la única superficie publicada.
- El despliegue manual `deploy/scripts/deploy.sh` se conserva como vía de contingencia.

## Alternativas consideradas
| Opción | Pros | Contras | Riesgo de seguridad |
|---|---|---|---|
| Receptor + tarea sync (elegida) | Reutiliza la infraestructura existente; SHA reproducible y rollback también de configs; sin puertos abiertos; una sola imagen extra | Los cambios del propio compose se aplican en el despliegue siguiente; sync escribe en el clon | Contenedor sync sin root, rootfs ro, escribe solo en su bind mount |
| Mantener `git pull && compose up` manual (ADR-0002) | Cero piezas nuevas | Sin rollback ni healthcheck; depende de entrar por SSH | Menor superficie, más error humano |
| Hornear configs en imágenes derivadas (mimir, gjallarhorn, odin, huginn) | Modelo 100 % inmutable | Cuatro imágenes más que construir y escanear; blackbox necesita las IPs WAN en runtime y Alertmanager el token; la review de configs se aleja de los archivos | Más superficie de supply chain |
| GitHub Actions haciendo SSH al appliance | Simple de razonar | Exige exponer SSH a internet o un runner propio; un secreto de acceso al host en GitHub | Alto |

## Consecuencias
- Positivas: despliegue al minuto de fusionar en `main`, reproducible por SHA, con healthcheck y
  rollback; los secretos siguen solo en el servidor (`deploy/.env`, `receiver.env`).
- Negativas / deuda asumida: dos imágenes propias en el informe de Trivy; el compose del CD se
  aplica con un despliegue de retraso cuando cambia; el resultado de las tareas sync no forma parte
  del healthcheck del receptor (queda en `docker logs`); el bootstrap inicial del servidor requiere
  `sudo` (clon, `.env`, `apps.yml`, sysctl) y lo hace `deploy/cd/bootstrap-midgard.sh`.
- Impacto en threat model: el webhook firmado y el receptor están cubiertos por el threat model de
  `despliegue-continuo`; en Yggdrasil se añade el bind mount de escritura del clon (T6, Gate 3).
- Condiciones de revisión: si el receptor incorpora hooks de pre-despliegue o `git sync` nativo,
  eliminar la tarea sync; si la latencia de "compose con un despliegue de retraso" molesta, mover el
  compose fuera del clon.
