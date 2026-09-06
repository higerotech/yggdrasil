# Changelog

Todos los cambios notables de este proyecto se documentan en este archivo.

El formato está basado en [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/),
y este proyecto se adhiere a [Versionado Semántico](https://semver.org/lang/es/).

## [Unreleased]

> Gate 1 (Design) listo para la aprobación del owner: ADR-0001 y ADR-0003 aceptados y frontera con Fenrir resuelta en ADR-0004. Al aprobarlo, cortar 0.2.0.

### Cambiado
- ADR-0001 (stack de métricas) y ADR-0003 (host-mode selectivo) pasan a `accepted` (2026-09-05). Charter (0.1.1) y `naming.md`: Frigate/Fenrir se desarrolla en el proyecto independiente `nvr-frigate`; el presupuesto de RAM de Yggdrasil queda en ≤ 1.5 GB sin depender de Frigate.
- Gates movidos de `docs/gates/` a `.ai-dlc/gates/` y ADR de `docs/02-design/adr/` a `docs/00-project/adr/`, alineando el árbol con el estándar AI-DLC polyrepo de la organización.
- C4 Container: el boundary de la plataforma pasa a id `yggdrasil` y Heimdall queda como `Container_Boundary` propio, de modo que el id `heimdall` designa lo mismo que en el C4 Context; el slot de tecnología muestra Prometheus, Alertmanager, Grafana y Node-RED en vez de "Docker".
- Diagramas: "Odín" con acento en los DFD del PRD y del threat model; los elementos del requirementDiagram usan los nombres nórdicos (Huginn y Muninn, Sleipnir, Mimir, Gjallarhorn, Odín, Nornas) con la tecnología en `type`, según `naming.md`.

### Añadido
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

[Unreleased]: https://github.com/higerotech/yggdrasil/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/higerotech/yggdrasil/releases/tag/v0.1.0
