# ADR-0002: Placement de despliegue — appliance local

* **Estado:** accepted
* **Fecha:** 2026-09-01
* **Decisores:** Jeremi
* **Fase AI-DLC:** 02-design
* **Versión:** 1.0.0
* **ID:** ADR-0002
* **Supersede / Superseded-by:** —
* **Controles OWASP afectados:** A02

## Contexto
Procedimiento de deployment placement por componente (guía PxD). El componente es clase E (especial): las sondas **deben** originarse físicamente en las interfaces WAN del hogar — medir el SLA de los ISPs desde la nube es conceptualmente imposible. Los datos (patrones de presencia) además deben residir localmente.

## Decisión
Todo el stack corre en el appliance (Ubuntu 24.04, Docker Compose). Candidato único por requisito físico y costo marginal $0 → ADR sin matriz PxD completa (proporcionalidad: costo < $10/mes y sin candidato alternativo viable). **CD:** repo en GitHub + GitHub Actions solo para lint/validación de configs; el despliegue al appliance es `git pull && docker compose up -d` vía script idempotente (patrón ya usado en el proyecto), pues no hay runner expuesto ni se justifica un pipeline push hacia una red doméstica.

## Alternativas consideradas
| Opción | Pros | Contras | Riesgo de seguridad |
|---|---|---|---|
| Appliance local (elegida) | Única que puede medir por WAN; datos en casa; $0 | Hardware limitado compartido | Superficie solo LAN/WG |
| Sonda cloud (Workers/Lambda) | Mediría "hacia" la casa | No mide el SLA de salida por cada ISP; requiere exponer endpoints | Exposición a internet |
| Híbrido (sonda local + TSDB cloud) | Descarga RAM | Envía patrones de presencia fuera de casa; costo recurrente | Fuga de datos confidenciales |

## Consecuencias
- Positivas: cero costo recurrente, cero exposición pública nueva.
- Negativas / deuda asumida: la disponibilidad del monitoreo depende del propio appliance (se auto-observa; un fallo total del host es punto ciego — mitigable a futuro con un heartbeat externo mínimo).
- Impacto en threat model: mantiene todos los datos dentro del trust boundary del hogar.
- Condiciones de revisión: si se necesita observar el appliance desde fuera (dead-man switch), evaluar un heartbeat gratuito (p. ej. healthchecks.io) en una ADR nueva.
