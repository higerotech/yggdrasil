# Gate 0 — Requirements (checklist)

* **Estado:** approved
* **Fecha:** 2026-09-01
* **Fase AI-DLC:** 01-requirements
* **Versión:** 0.1.0

- [x] Charter, glosario, clasificación de datos (fase 00)
- [x] PRD F-001 con requisitos funcionales y no funcionales
- [x] Escenarios de abuso documentados
- [x] Mapeo ASVS L1 de requisitos de seguridad
- [x] Evidencia: journey · requirementDiagram · DFD + quadrant DREAD
- [x] Umbral SLO de pérdida confirmado por el owner (1 % en 5 min) y percentiles de latencia a registrar (p90, p95, p99) — 2026-09-05
- [x] Umbrales p95 confirmados por el owner: < 500 ms servicios estándar (Degradado), < 200 ms llamadas críticas (indicador `apto_llamadas`); throughput ≥ 800 Mbps por WAN (80 % del nominal); propósito del sondeo y disponibilidad mensual del hogar como objetivo (RF08) — 2026-09-05
- [x] Hosts de sondeo confirmados por el owner: 1.1.1.1, 8.8.8.8, `https://www.gstatic.com/generate_204` — 2026-09-05
- [x] **Aprobación del owner** (2026-09-05): charter, glosario, clasificación de datos y PRD en `approved`; `0.1.0` cortada vía `release/0.1.0`

**Gate 0 cerrado el 2026-09-05.** Versión `0.1.0` en CHANGELOG; tag `v0.1.0` en `main`. Siguiente: Gate 1 (Design) → `0.2.0`.
