# ADR-0013: Loki, los logs de Hive en midgard, y Gná, que los lleva desde nidavellir

* **Estado:** accepted
* **Fecha:** 2026-11-20
* **Decisores:** Jeremi
* **Fase AI-DLC:** 02-design
* **Versión:** 1.0.0
* **ID:** ADR-0013
* **Supersede / Superseded-by:** —
* **Controles OWASP afectados:** A09 (los logs de seguridad de Hive se guardan fuera del host que los escribe, y no se
  pueden borrar desde él), A01 (Gná no tiene el socket de Docker: un proxy solo le deja leer), A05 (sin puertos
  publicados salvo la puerta, que solo atiende a nidavellir), A02 (los logs del IdP pueden llevar datos personales:
  90 días y acceso solo por Odín)

## Contexto

HIG-140 de Hive (Gate 5) pide los tres pilares de la observabilidad. Hive ya tiene métricas (Mimir, con sus alertas de
seguridad desde la 0.5.27) y trazas (Saga, ADR-0008). Los logs se quedan en los `json-file` de cada contenedor en
nidavellir:

- **Se pierden pronto:** cada contenedor guarda 3 ficheros de 10 MB. El audit de Andvari escribe unos 10 MB al día, así
  que su historia dura unos tres días.
- **No se pueden consultar juntos:** para seguir un incidente hay que entrar por ssh y leer contenedor a contenedor.
- **Viven en el host que se investiga:** un atacante con root en nidavellir puede borrarlos.

Decisión de Jeremi del 2026-11-16 en HIG-140: Loki en Yggdrasil para el pilar de logs, que se consulta desde Grafana.
El nombre Loki estaba reservado en `naming.md` para esto.

Volumen medido el 2026-11-20 en nidavellir, en 24 h:

| Contenedores | Líneas | Bytes |
|---|---|---|
| `hive-*` (11 contenedores de la aplicación y 5 de Zitadel) | unas 250 | unos 30 KB |
| `andvari-openbao` (audit log, JSON con valores HMAC, líneas de hasta 30 KB) | 666 | 9,7 MB |
| `bifrost-nats`, `hermod-rabbitmq` | 0 | 0 |

## Decisión

### Loki en midgard

- **Grafana Loki 3.7.9** en modo monolítico (`-target=all`), con almacén local en el SSD: `/srv/rapido/loki`, dueño
  10001, como Saga. Sin el SSD montado no arranca (`create_host_path: false`). Es la misma imagen, por digest, que
  usa el Loki de morocota en nidavellir.
- **90 días de retención** (`retention_period: 2160h`, con el compactor), decisión de Jeremi del 2026-11-20: deja
  margen para investigar un compromiso que se descubre tarde. Con el volumen medido son menos de 1 GB.
- **Sin borrado por API** (`deletion_mode: disabled`): el 3100 lo alcanza nidavellir, y un log de seguridad no se
  borra desde el host que lo escribió. Los datos solo salen por la retención.
- **Ningún puerto publicado.** Odín la consulta y Mimir la lee por `heimdall`.
- **La puerta de Loki**, `yggdrasil-loki-puerta`, igual que la de Saga: socat publica el 3100 solo en la IP de la LAN
  de midgard y no acepta más origen que nidavellir (`LOKI_EMISORES`, `192.168.10.2/32`). Entra en Loki por su propia
  red, `yggdrasil_loki_entrada`, que no alcanza a Mimir ni a Odín.
- **Endurecida como el resto:** `read_only`, `cap_drop: ALL`, `no-new-privileges`, `mem_limit: 512m` y
  `GOMEMLIMIT=400MiB`. En reposo usa unos 43 MiB (medido en local).
- **Vigilada por Mimir** (`rules/loki-alertas.yml`):
  - `LokiCaido`: Mimir no la lee durante 5 min.
  - `LokiSinLogs`: 2 h sin recibir una línea. Andvari escribe en su audit al menos una vez por hora, así que es Gná que
    no entrega o la puerta cerrada.
  - `LokiDescartaLogs`: una línea descartada es un log de seguridad que no se guardó.

### Gná en nidavellir

Gná es la mensajera de Frigg, que cabalga por cielo y mar llevando recados entre los mundos (nombre elegido por Jeremi
el 2026-11-20). Es **Grafana Alloy v1.21.3** (`deploy/nidavellir/gna.yml`).

- **Lleva Hive y su plataforma:** `hive-*` (también los de Zitadel, `hive-idp*`), `bifrost-nats`, `hermod-rabbitmq` y
  `andvari-openbao`, con su audit log (decisión de Jeremi del 2026-11-20). Nada más de nidavellir: morocota tiene su
  propio Loki, y bragi no es de Hive.
- **Etiquetas:** `host` y `contenedor`, pocas y fijas.
- **Sin el socket de Docker.** El socket da root sobre el host. Gná habla con `gna-docker`
  (wollomatic/socket-proxy 1.13.2), el único que lo monta, en solo lectura, en una red interna sin salida:
  - solo atiende a `gna`;
  - solo deja `GET` de `/_ping`, `/version`, `/networks`, la lista de contenedores y, de cada uno, su inspección y sus
    logs. Nada de `/archive` ni `/export`, que sacarían ficheros de los contenedores (por ejemplo, de Andvari), ni de
    `POST`.

  `prueba-gna.sh` lo comprueba en el CI, con controles negativos.
- **Endurecida igual:** Alloy corre como su usuario (473), `read_only`, `cap_drop: ALL`; su interfaz de depuración
  queda en el loopback del contenedor. Las posiciones de lectura viven en un volumen: tras un reinicio sigue donde lo
  dejó.
- **Se instala a mano**, como el relé de Saga: nidavellir no tiene un clon del repo. Thor la vigila
  (`THOR_CONTENEDORES`), y `ServicioDeHostCaido` la nombra si cae.

### Lo que no se hace aquí

- Los logs de midgard no van a Loki: no son de Hive. Si se quiere, se añade un Gná en midgard.
- Sin enlace de los logs a sus trazas: Hive no escribe el id de traza en sus logs. Lo decide la fase 06 de Hive.
- Sin reglas de alerta en Loki (ruler): las alertas de seguridad salen de los contadores de Hive, en Mimir
  (HIG-140, punto 2).

## Alternativas consideradas

| Opción | Pros | Contras |
|---|---|---|
| **Loki en midgard, Alloy en nidavellir** | Los logs salen del host que se investiga; un solo Grafana con métricas, trazas y logs; el mismo patrón que Saga | Una puerta más en la LAN de midgard; el agente necesita ver Docker |
| Loki en nidavellir, junto a Hive | Sin tráfico entre hosts | Los logs se quedan en el host comprometido; Odín tendría que alcanzar nidavellir |
| Reutilizar el Loki de morocota | Ya corre | Es de otro proyecto, con otro ciclo de vida y otra retención; mezcla datos de dos sistemas |
| Promtail como agente | Más sencillo | Fin de vida desde el 2026-03-02; Alloy es su sucesor |
| Alloy con el socket de Docker montado | Sin proxy | Quien comprometa a Gná es root en nidavellir |
| Proxy de Tecnativa (el de despliegue-continuo) | Ya se usa en el repo | Permite por familias (`CONTAINERS=1` abre también `/archive` y `/export`); no filtra por ruta |
| Seguir con los json-file | Nada que operar | Tres días de historia, sin consulta conjunta, borrables desde el host |

Es un único candidato viable a coste cero, autoalojado. Por proporcionalidad, la ADR va sin matriz PxD.

## Consecuencias

- **El presupuesto de RAM del stack** (suma de `mem_limit` en midgard) pasa de 2224 a 2768 MB, contando la puerta de
  Saga, que faltaba en la suma. En reposo, Loki usa unos 43 MiB. midgard tenía 5 GB disponibles el 2026-11-20.
- **Espacio en el SSD:** unos 10 MB al día por 90 días, menos de 1 GB. Le quedan 805 GB.
- **Datos personales en Loki:** los logs de Hive no llevan datos personales (RS19 de Hive), pero los de Zitadel pueden
  llevar un correo o una IP, y el audit de Andvari lleva valores con HMAC. Se guardan 90 días y solo se ven desde Odín,
  con su usuario. Queda anotado en `data-classification.md`.
- **Desde nidavellir se puede consultar Loki** por la puerta. Loki no separa la ingesta de la consulta por red. Se
  acepta: lo que hay en Loki salió de nidavellir, y el borrado está desactivado.
- **Los cambios de compose llegan con el despliegue siguiente** (`docker-compose.cd.yml`): tras la release, Loki y su
  puerta se levantan con un `up -d` a mano o con el despliegue que venga después.

## Condiciones de revisión

- Los logs ocupan más de lo previsto: el SSD baja del 50 % libre.
- La fase 06 de Hive pide enlazar logs y trazas, o alertas sobre los logs.
- Entra en Loki un emisor que no sea de nidavellir, o uno que no sea propio.
