# Changelog

Todos los cambios notables de este proyecto se documentan en este archivo.

El formato está basado en [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/),
y este proyecto se adhiere a [Versionado Semántico](https://semver.org/lang/es/).

## [Unreleased]

### Cambiado
- Plataforma renombrada a **Yggdrasil** (antes propuesta genérica); convención de nombres nórdica en `docs/00-project/naming.md`.
- Servicio F-001 renombrado **Heimdall**; componentes: Huginn/Muninn (sondas), Sleipnir (throughput), Mimir (Prometheus), Gjallarhorn (Alertmanager), Odín (Grafana), Nornas (Node-RED), Ratatosk (MQTT).
- Espacio de tópicos MQTT: `casa/...` → `midgard/...`.
- SLI de latencia: de p95 único a percentiles p90, p95 y p99 por WAN (glosario, PRD, contratos de métricas); el umbral SLO de pérdida queda confirmado en 1 % sobre 5 min (Gate 0 parcialmente validado el 2026-09-05).
- Umbrales SLO cerrados por el owner (2026-09-05): p95 < 500 ms para servicios estándar (Degradado) y < 200 ms para llamadas críticas (indicador `apto_llamadas`); throughput ≥ 800 Mbps por WAN (80 % del nominal). Máquina de estados, glosario y charter actualizados. Gate 0 solo espera confirmar los hosts de sondeo y la aprobación formal.

### Añadido
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

> Nota: Gate 0 y Gate 1 quedan pendientes de validación humana; al aprobarlos, cortar 0.1.0 y 0.2.0.
