# Gate 1 — Design (checklist)

* **Estado:** review
* **Fecha:** 2026-09-01
* **Fase AI-DLC:** 02-design
* **Versión:** 0.1.0

- [x] C4 Container + flujos (sequence) + entidad núcleo (state) + ER/class
- [x] Threat model STRIDE + DREAD con controles trazables
- [x] ADR-0001 stack de métricas (**proposed — requiere aceptación**)
- [x] ADR-0002 placement appliance local (accepted, proporcionalidad)
- [x] ADR-0003 red de contenedores host-mode selectivo (**proposed — requiere aceptación**)
- [x] Contratos: métricas Prometheus + tópicos MQTT
- [ ] **Validación humana pendiente**: aceptar ADR-0001 y ADR-0003; confirmar presupuesto RAM con Frigate futuro

Al aprobar: cortar `0.2.0` en CHANGELOG.
