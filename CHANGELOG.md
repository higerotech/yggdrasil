# Changelog

Todos los cambios notables de este proyecto se documentan en este archivo.

El formato está basado en [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/),
y este proyecto se adhiere a [Versionado Semántico](https://semver.org/lang/es/).

## [Unreleased]

> Gate 3 (Testing) en curso sobre el despliegue de `v0.4.0` en midgard (TA-01 superado el 2026-09-06 al tercer intento: paquetes GHCR privados por defecto y primer arranque de Grafana de ~3 min; `health_timeout` 300 s): TA-01 despliegue continuo, aceptación de RF01–RF09, seguridad TS-01..TS-10, RNF01/RNF02 y calibración del techo de throughput. Al aprobarlo, cortar 0.5.0.

## [0.4.6] - 2026-09-08

Hotfix sobre la 0.4.5, a partir de TA-05 (quórum) en Gate 3.

### Corregido
- `wan:perdida_pct:5m` promediaba los fallos de todos los objetivos ICMP, así que un solo objetivo inalcanzable (1.1.1.1 bloqueado en TA-05) contaba como 50 % de pérdida y disparaba `WanDegradada` y `WanNoAptaLlamadas` en ambas WAN aunque el enlace estuviera sano. La regla excluye ahora los objetivos sin ninguna respuesta en la ventana: la pérdida del enlace es la de los objetivos que sí responden.
- Las sondas ICMP se raspan cada 5 s (antes 15 s): con 120 muestras por ventana de 5 min la resolución de la pérdida es 0,8 %, coherente con el umbral del 1 %; a 15 s era 2,5 %.

## [0.4.5] - 2026-09-08

Hotfix sobre la 0.4.4, tras la primera medición de Sleipnir `0.2.0` en producción.

### Corregido
- Sleipnir `0.2.1`: la elección automática de servidor de Ookla puede caer en uno lento y simular una degradación del ISP (wan2: 312 Mbps contra M21 Telecom frente a 941 contra Thundernet y 939 contra MDS Telecom en el mismo minuto). `OOKLA_SERVER_ID` admite ahora varios IDs separados por coma: la sonda mide contra cada uno y publica el máximo por sentido y el mejor ping, y registra cada servidor en el log. Los mensajes de la sonda van a stderr para no contaminar el resultado capturado.

## [0.4.4] - 2026-09-08

Hotfix de CI/CD sobre la 0.4.3.

### Corregido
- El relanzamiento automático del workflow `build` (segundo despliegue cuando cambia el Compose) compartía grupo de concurrencia con la ejecución del push y la cancelaba en su último segundo: el `workflow_run` del push llegaba como `cancelled`, el receptor lo ignoraba y solo se desplegaba una vez, con el Compose anterior. El grupo incluye ahora el evento, así que ambas ejecuciones terminan y el receptor despliega dos veces como estaba previsto.

## [0.4.3] - 2026-09-07

Release de corrección desde `develop` durante Gate 3: las lecturas de throughput de Heimdall eran inservibles (calibración de TA-07).

### Corregido
- Sleipnir `0.2.0` mide con la CLI oficial de Ookla (`1.2.0`, pineada por sha256 en el `Dockerfile`) ligada a cada interfaz WAN; `speedtest-cli` daba 76–188 Mbps de bajada en el i3 frente a los 939 Mbps reales medidos en TA-07. `SLEIPNIR_MODO` pasa a `ookla` por defecto (`speedtest` e `iperf3` siguen disponibles) y `OOKLA_SERVER_ID` permite fijar servidor.
- Evidencia de la calibración de TA-07 en `docs/04-testing/test-plan.md`: techo de la cadena de medición ≥ 939 Mbps, dos muestras por WAN; `wan1` degradada a 16 Mbps de bajada tras la caída del ISP1 y recuperada a 940/940 a las 18:58 UTC.

### CI/CD
- El workflow `build` se relanza a sí mismo cuando un push a `main` cambia el Compose, para que el receptor despliegue una segunda vez con el Compose ya actualizado (PR #21).

## [0.4.2] - 2026-09-07

Hotfix sobre la 0.4.1, a partir de lo observado al desplegarla en midgard.

### Corregido
- Mimir no aplicaba `prometheus.yml` nuevo al recargar: el fichero estaba montado suelto y el checkout de `sync-host` lo sustituye por un inodo nuevo que el bind mount no sigue. Se monta el directorio `prometheus/` completo. Ratatosk y Nornas, cuyos ficheros de configuración solo se leen al arrancar, se recrean en cada despliegue del CD (`YGG_REV`).
- `nornas-init` se ejecutaba en paralelo a `sync-host` y leía el flujo del checkout anterior, así que la 0.4.1 no actualizó la pestaña de Heimdall. `sync-host` deja el marcador `deploy/.sync/rev` y `nornas-init` espera a que coincida con `IMAGE_TAG` antes de importar.
- Flujo de Nornas: si `WanDegradada` seguía activa al terminar la recuperación de una caída, el enlace quedaba `saludable` hasta el siguiente aviso (4 h). El traductor recuerda la degradación por WAN y al salir de Recuperando publica `degradado` cuando corresponde.

## [0.4.1] - 2026-09-07

Hotfix sobre la 0.4.0 tras la primera caída real detectada por Heimdall (ISP1, 2026-09-07 13:05 UTC).

### Corregido
- Flujo de Nornas: el estado del hogar se calculaba solo con las WAN de las que ya había habido alertas, así que la caída de `wan1` publicó `midgard/hogar/internet/estado = caido` con `wan2` sana. Ahora considera todas las WAN (`YGG_WANS`, por defecto `wan1,wan2`) y una WAN sin alertas cuenta como saludable. Una WAN caída publica además `apto_llamadas = no`, y al volver a saludable se restaura el último valor conocido del indicador.
- Mimir no ingería las métricas de Sleipnir: Prometheus 3 rechaza un objetivo sin `Content-Type` y busybox httpd no lo envía (`SondaCaida` activa desde el primer despliegue). El job `sleipnir` declara `fallback_scrape_protocol: PrometheusText0.0.4`.
- `nornas-init` reimporta la pestaña Heimdall cuando cambia la revisión del flujo (hash de `src/*.js` en el nodo de pestaña), conservando las demás pestañas del editor; antes solo importaba la primera vez.

## [0.4.0] - 2026-09-05

Release de arranque de Gate 3. Lleva a `main` el despliegue continuo (ADR-0005) y los servicios de plataforma Ratatosk y Nornas (ADR-0006); su primer despliegue automático en midgard es la primera prueba de aceptación (TA-01). Con esta release la convención de versiones se desplaza un menor: el cierre de Gate 3 cortará 0.5.0.

### Añadido
- Workflow `build`: si el commit cambia `docker-compose*.yml`, se relanza a sí mismo por `workflow_dispatch` para que el receptor haga un segundo despliegue con el Compose nuevo (compensa el desfase de un despliegue del Compose dentro del clon, observado al desplegar la 0.4.2). Documentado en `deploy/cd/README.md`.
- Gate 3 abierto: `docs/04-testing/test-plan.md` (estrategia en cuatro capas, alcance sobre la arquitectura, trazabilidad requisito ↔ prueba con `verifies`, casos TA-01..TA-14, seguridad TS-01..TS-10, transiciones de estado, calibración del techo de throughput y criterio de salida) y checklist `.ai-dlc/gates/gate-3-testing.md`.
- ADR-0006: Ratatosk (Mosquitto 2.0.22) y Nornas (Node-RED 4.1.14) pasan a ser servicios de plataforma desplegados por el Compose de Yggdrasil, ya que no existía broker ni Node-RED en midgard. Ratatosk con `allow_anonymous false`, una credencial por cliente (`nornas`, `frigate`, `iot`) generada al arrancar desde `.env`, ACL por tópico (control T3 propio) y límites; Nornas con editor autenticado (`settings.js`), secreto de credenciales estable y webhook de Alertmanager por la red interna; `nornas-init` importa el flujo de Heimdall por la Admin API e inyecta las credenciales MQTT. RNF01 sube a 1408 MB. El bootstrap completa las claves nuevas de `.env` sin tocar las existentes.
- ADR-0005: despliegue continuo con el receptor de `higerotech/despliegue-continuo` (supersede la sección CD de ADR-0002). `build-and-push.yml` publica `yggdrasil-sleipnir` y `yggdrasil-sync` en GHCR con tag `sha-<7>`; `deploy/docker-compose.cd.yml` añade las tareas `sync-host` (checkout del commit, render con las IPs de las WAN, recarga de blackbox) y `sync-net` (recarga de Mimir y Gjallarhorn); `deploy/cd/bootstrap-midgard.sh` prepara el appliance con sudo (sysctl, clon como `deploy`, `.env`, inventario del receptor) y `deploy/cd/README.md` documenta webhook, operación y rollback.
- Prerrequisitos verificados en midgard el 2026-09-05: Ubuntu 24.04.4, Docker 29.8 y Compose v5.5, `wan1`/`wan2` con `ip rule from`, docker0 en 172.17.0.1, receptor sano con túnel; pendientes `ping_group_range`, reglas nftables y la ausencia de Node-RED y Mosquitto (Nornas y Ratatosk).

### Cambiado
- `render.sh` tolera una WAN sin IPv4: conserva la última IP renderizada con aviso y solo aborta si no hay render previo. Motivado por la caída de `wan2` en midgard durante el bootstrap del 2026-09-05.
- Charter (0.1.2), PRD, `architecture.md` (C4 Container y notas), `threat-model.md` (filas MQTT y Node-RED, T3) y clasificación de datos: Ratatosk y Nornas dejan de ser "existentes" y pasan a servicios propios; `NORNAS_URL` por defecto `http://nornas:1880/heimdall/alertas`; Gjallarhorn ya no necesita `host.docker.internal`.
- Imagen de Sleipnir pasa a `ghcr.io/higerotech/yggdrasil-sleipnir` con `IMAGE_TAG`; `deploy/scripts/deploy.sh` queda como vía manual de contingencia.

## [0.3.0] - 2026-09-05

Gate 2 (Implementation) aprobado. Primeros artefactos ejecutables en `deploy/`, validados con las herramientas oficiales en local y en CI; imágenes re-pineadas tras el triaje de CVEs; documentación de la fase 03 con el historial del repo derivado del git log.

### Añadido
- Gate 2 (Implementation) aprobado por el owner: `config-baseline.md` y `cadena-suministro.md` en `approved`; política de triaje de CVEs y residual aceptados.
- `docs/03-implementation/config-baseline.md` (inventario de artefactos y trazabilidad a requisitos, pipeline de render, desviaciones respecto a Gate 1, validación equivalente a SAST, cadena de suministro, secretos y riesgos que entran a Gate 3, con `classDiagram` del traductor de Nornas), `cadena-suministro.md` (triaje de CVEs, residual por imagen, exposición real y política propuesta) y `repo-history.md` generado desde el git log con `scripts/generar-historial.py` (vistas de `main` y `develop`, tabla tag ↔ versión ↔ decisión y bitácora).
- `scripts/gitgraph_from_log.py` (copiado del skill AI-DLC) y `scripts/generar-historial.py`; escaneo semanal programado de Trivy en `validar-configs.yml`; historial de pines en `deploy/imagenes.md`.
- `deploy/docker-compose.yml` (Gate 2): Huginn y Muninn (blackbox_exporter v0.27.0, host-mode, `cap_add NET_RAW`), Sleipnir (imagen propia sobre alpine 3.22 pineada por digest), Mimir (Prometheus v3.5.0, retención 30 d), Gjallarhorn (Alertmanager v0.28.1) y Odín (Grafana 12.1.1, único puerto publicado en la IP LAN); `mem_limit` total 1088 MB (RNF01), `restart: unless-stopped` (RNF02), `no-new-privileges` y rootfs de solo lectura.
- Configuraciones del contrato: módulos blackbox `icmp_wan1/2` y `tls_wan1/2` con `source_ip_address`; scrape de Prometheus cada 15 s; recording rules `wan:perdida_pct:5m`, `wan:latencia_p90|p95|p99:5m`, `wan:up`, `hogar:up`, `wan:apto_llamadas`, `wan:disponibilidad:30d`, `hogar:disponibilidad:30d`; alertas `WanCaida`, `WanDegradada`, `WanNoAptaLlamadas`, `WanThroughputBajo`, `SleipnirSinMedicion`, `SondaCaida`; Alertmanager con inhibición por WAN, webhook Bearer a Nornas y receptor nulo para throughput hasta calibrar; datasource y dashboard `heimdall-sla` provisionados en Grafana.
- Sleipnir: `sleipnir.sh` alterna wan1/wan2 cada 3 h (speedtest-cli o iperf3 con bind a la IP de la WAN) y publica `wan_throughput_mbps{wan,direccion}` por HTTP en :9469.
- Flujo de Nornas `heimdall-alertas.json`: valida el token Bearer, traduce el webhook a `midgard/wan/<id>/estado`, `midgard/wan/<id>/apto_llamadas`, `midgard/hogar/internet/estado` y `midgard/wan/<id>/alerta`, y resuelve Recuperando → Saludable tras 5 min.
- `deploy/scripts/render.sh` (plantillas + IPs de las WAN + recarga en caliente) y `deploy/scripts/deploy.sh` (despliegue idempotente, ADR-0002); `deploy/.env.example` en rango RFC 5737; `deploy/README.md`; `deploy/imagenes.md` con digests.
- Workflow `validar-configs.yml`: compose config, promtool, amtool, blackbox `--config.check`, JSON, build de Sleipnir, ShellCheck, gitleaks y Trivy (informe) en cada PR que toque `deploy/`.
- Checklist `.ai-dlc/gates/gate-2-implementation.md`.

### Cambiado
- Imágenes re-pineadas tras el triaje de Trivy: Prometheus `v3.5.0` → `v3.14.0`, Alertmanager `v0.28.1` → `v0.34.0`, blackbox_exporter `v0.27.0` → `v0.28.0`, Grafana `12.1.1` → `12.4.10`; Sleipnir `0.1.1` con `apk upgrade` en el build. Los hallazgos HIGH/CRITICAL pasan de 41 a 123 por imagen a entre 2 y 6, salvo blackbox (40, sin release más nueva; mitigado por red).
- Desviaciones de implementación reflejadas en `architecture.md` (contenedor Sleipnir, `Rel` de scrape, quórum con TCP+TLS, percentiles sobre `probe_icmp_duration_seconds{phase="rtt"}`, métricas y alertas nuevas en los contratos), `threat-model.md` (T4 con token Bearer), PRD (host `www.gstatic.com:443` por TCP+TLS), glosario y ADR-0003 (nota de implementación sobre docker0): tercer objetivo por TCP+TLS (el prober http de blackbox no fija IP de origen); token en cabecera `Authorization: Bearer` en vez de URL; Sleipnir sirve su textfile por HTTP en lugar de node_exporter; latencia desde `probe_icmp_duration_seconds{phase="rtt"}`; puertos host-mode ligados a la IP de docker0.

## [0.2.0] - 2026-09-05

Gate 1 (Design) aprobado. Arquitectura y threat model en `approved`; los cuatro ADR en `accepted`; hallazgos de la revisión inicial cerrados.

### Cambiado
- ADR-0001 (stack de métricas) y ADR-0003 (host-mode selectivo) pasan a `accepted` (2026-09-05). Charter (0.1.1) y `naming.md`: Frigate/Fenrir se desarrolla en el proyecto independiente `nvr-frigate`; el presupuesto de RAM de Yggdrasil queda en ≤ 1.5 GB sin depender de Frigate.
- Gates movidos de `docs/gates/` a `.ai-dlc/gates/` y ADR de `docs/02-design/adr/` a `docs/00-project/adr/`, alineando el árbol con el estándar AI-DLC polyrepo de la organización.
- C4 Container: el boundary de la plataforma pasa a id `yggdrasil` y Heimdall queda como `Container_Boundary` propio, de modo que el id `heimdall` designa lo mismo que en el C4 Context; el slot de tecnología muestra Prometheus, Alertmanager, Grafana y Node-RED en vez de "Docker".
- Diagramas: "Odín" con acento en los DFD del PRD y del threat model; los elementos del requirementDiagram usan los nombres nórdicos (Huginn y Muninn, Sleipnir, Mimir, Gjallarhorn, Odín, Nornas) con la tecnología en `type`, según `naming.md`.

### Añadido
- Gate 1 (Design) aprobado por el owner: `architecture.md` y `threat-model.md` pasan a `approved`; ADR-0001..0004 en `accepted`.
- ADR-0004: frontera con Fenrir (Frigate NVR), proyecto independiente con métricas y monitoreo propios; la integración con Yggdrasil será una feature futura con su propio PRD y ADR.
- Trazabilidad de RF02, RF06, RF09 y RNF02 en el requirementDiagram del PRD; todos los requisitos quedan enlazados a un componente que los satisface. El diagrama se divide en dos vistas (medición y alertado; observabilidad, no funcionales y seguridad) para respetar el límite de ~12 nodos y renderizar legible.

## [0.1.0] - 2026-09-05

Primer corte: Gate 0 (Requirements) aprobado. Incluye las fases 00 y 01 en `approved` y los borradores de la fase 02 (arquitectura, threat model y ADRs) camino a Gate 1.

### Cambiado
- Plataforma renombrada a **Yggdrasil** (antes propuesta genérica); convención de nombres nórdica en `docs/00-project/naming.md`.
- Servicio F-001 renombrado **Heimdall**; componentes: Huginn/Muninn (sondas), Sleipnir (throughput), Mimir (Prometheus), Gjallarhorn (Alertmanager), Odín (Grafana), Nornas (Node-RED), Ratatosk (MQTT).
- Espacio de tópicos MQTT: `casa/...` → `midgard/...`.
- SLI de latencia: de p95 único a percentiles p90, p95 y p99 por WAN (glosario, PRD, contratos de métricas); el umbral SLO de pérdida queda confirmado en 1 % sobre 5 min (Gate 0 parcialmente validado el 2026-09-05).
- Umbrales SLO cerrados por el owner (2026-09-05): p95 < 500 ms para servicios estándar (Degradado) y < 200 ms para llamadas críticas (indicador `apto_llamadas`); throughput ≥ 800 Mbps por WAN (80 % del nominal). Máquina de estados, glosario y charter actualizados.

### Añadido
- Gate 0 (Requirements) aprobado por el owner: hosts de sondeo confirmados (1.1.1.1, 8.8.8.8, `https://www.gstatic.com/generate_204`); charter, glosario, clasificación de datos y PRD pasan a `approved`.
- `naming.md` con topología de mundos (Midgard edge, Asgard nube, Bifrost) y nombres reservados.
- Charter, glosario y clasificación de datos (fase 00).
- PRD `isp-sla-monitor` con escenarios de abuso, C4 Context, journey, requirementDiagram y threat assessment inicial (fase 01, hacia Gate 0).
- `architecture.md` con C4 Container, sequence, state, ER, class y contratos de métricas/MQTT (fase 02, hacia Gate 1).
- `threat-model.md` STRIDE + DREAD del servicio de monitoreo SLA.
- ADR-0001 (stack de métricas, proposed), ADR-0002 (placement en appliance local), ADR-0003 (network_mode host para sondas).
- `LICENSE` con la GNU Affero General Public License v3.0 (`AGPL-3.0`); referencia en README y charter.
- RF07 y tabla de umbrales SLO en el PRD; recording rules `wan:latencia_p90|p95|p99:5m` en `architecture.md`.
- Propósito del sondeo, RF08 (disponibilidad mensual por WAN y del hogar) y RF09 (SLO de throughput) en el PRD; hosts de sondeo por defecto; escenarios de latencia alta sin pérdida, cierre de mes y falso positivo de throughput.
- Contratos nuevos en `architecture.md`: recording rules `wan:up`, `hogar:up`, `wan:disponibilidad:30d`, `hogar:disponibilidad:30d` y `wan:apto_llamadas`; tabla de alertas (`WanCaida`, `WanDegradada`, `WanNoAptaLlamadas`, `WanThroughputBajo`); tópicos MQTT `midgard/wan/<id>/apto_llamadas` y `midgard/hogar/internet/estado`.
- Repositorio publicado en `higerotech/yggdrasil` con GitFlow: `README.md`, `.gitignore`, `.gitattributes` (LF) y `gitflow-guard.yml`; `main` protegida por ruleset (solo PR con merge commit desde `develop`, `release/*` o `hotfix/*`).

[Unreleased]: https://github.com/higerotech/yggdrasil/compare/v0.4.6...HEAD
[0.4.6]: https://github.com/higerotech/yggdrasil/compare/v0.4.5...v0.4.6
[0.4.5]: https://github.com/higerotech/yggdrasil/compare/v0.4.4...v0.4.5
[0.4.4]: https://github.com/higerotech/yggdrasil/compare/v0.4.3...v0.4.4
[0.4.3]: https://github.com/higerotech/yggdrasil/compare/v0.4.2...v0.4.3
[0.4.2]: https://github.com/higerotech/yggdrasil/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/higerotech/yggdrasil/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/higerotech/yggdrasil/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/higerotech/yggdrasil/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/higerotech/yggdrasil/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/higerotech/yggdrasil/releases/tag/v0.1.0
