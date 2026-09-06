# ADR-0001: Stack de métricas y alertado (Prometheus + Grafana)

* **Estado:** accepted
* **Fecha:** 2026-09-01
* **Decisores:** Jeremi
* **Fase AI-DLC:** 02-design
* **Versión:** 1.0.0
* **ID:** ADR-0001
* **Supersede / Superseded-by:** —
* **Controles OWASP afectados:** A01, A05, A06

## Contexto
RF01–RF06 exigen sondeo activo por WAN, reglas SLO, 30 días de retención, dashboards y alertas, en un host con 8 GB de RAM que además hospedará Frigate (desplegado desde el proyecto `nvr-frigate`, ADR-0004). Origen: `docs/01-requirements/isp-sla-monitor.md`.

## Decisión
Prometheus + blackbox_exporter + Alertmanager + Grafana, en Docker Compose con límites de memoria explícitos (`mem_limit`). Presupuesto estimado: Prometheus ~300–500 MB, Grafana ~150–250 MB, blackbox/AM ~50 MB c/u — dentro de RNF01. Es además el stack con mayor valor demo/didáctico para el resto de la plataforma (Frigate, node_exporter y MQTT ya tienen exporters/integraciones nativas).

## Alternativas consideradas
| Opción | Pros | Contras | Riesgo de seguridad |
|---|---|---|---|
| Prometheus + Grafana (elegida) | Ecosistema estándar, reglas SLO nativas, extensible a toda la plataforma | Mayor RAM que opciones mínimas | Superficie conocida y bien documentada |
| VictoriaMetrics single-node + Grafana | ~50% menos RAM, compatible PromQL | Menos didáctico; vmalert añade otra pieza | Similar |
| Telegraf + InfluxDB 2 + Grafana | Todo-en-uno de colección | InfluxDB pesado en 8 GB; Flux en desuso | Similar |
| Uptime Kuma | Simplísimo, UI lista | No mide por interfaz de origen ni SLO por WAN → no cumple RF01 | Menor superficie |

## Consecuencias
- Positivas: un solo lenguaje de consulta (PromQL) para toda la plataforma futura; alertas con deduplicación seria.
- Negativas / deuda asumida: la RAM del appliance se comparte con Frigate, que se presupuesta en `nvr-frigate` (ADR-0004); si el conjunto aprieta, migrar la TSDB a VictoriaMetrics (compatible) — condición de revisión.
- Aceptada por el owner el 2026-09-05.
- Impacto en threat model: añade Grafana (T1) y API Prometheus (T2) como superficies; controles definidos en threat-model.md.
