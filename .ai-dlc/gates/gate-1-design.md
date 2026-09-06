# Gate 1 — Design (checklist)

* **Estado:** review
* **Fecha:** 2026-09-01
* **Fase AI-DLC:** 02-design
* **Versión:** 0.1.0

- [x] C4 Container + flujos (sequence) + entidad núcleo (state) + ER/class
- [x] Threat model STRIDE + DREAD con controles trazables
- [x] ADR-0001 stack de métricas (accepted por el owner el 2026-09-05)
- [x] ADR-0002 placement appliance local (accepted, proporcionalidad)
- [x] ADR-0003 red de contenedores host-mode selectivo (accepted por el owner el 2026-09-05)
- [x] Contratos: métricas Prometheus + tópicos MQTT
- [x] ADR-0004 frontera con Fenrir (Frigate): proyecto independiente `nvr-frigate` con métricas y monitoreo propios; el presupuesto de RAM de Yggdrasil se mantiene en ≤ 1.5 GB (RNF01) — 2026-09-05
- [ ] **Aprobación del owner** para cerrar Gate 1: pasar `architecture.md` y `threat-model.md` a `approved` y cortar `0.2.0` vía `release/0.2.0`

Al aprobar: cortar `0.2.0` en CHANGELOG.
