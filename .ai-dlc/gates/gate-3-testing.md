# Gate 3 — Testing (checklist)

* **Estado:** draft
* **Fecha:** 2026-09-05
* **Fase AI-DLC:** 04-testing
* **Versión:** 0.4.0

> Adaptación: Heimdall es COTS configurado, sin pirámide unit→e2e. La verificación es **aceptación
> sobre el sistema real** (con fallos inducidos en las WAN) + **seguridad** (DAST equivalente:
> puertos, autenticación, ACL, secretos) + **rendimiento contra RNF01 y los SLO**. Artefacto:
> `docs/04-testing/test-plan.md`. La release `0.4.0` es la de **arranque**: lleva el despliegue
> continuo a `main` y su primer despliegue en midgard es TA-01. El cierre de este gate corta `0.5.0`
> (la convención sugerida del skill se desplaza un menor a partir de aquí).

- [ ] TA-01 Despliegue continuo: build → GHCR → webhook → receptor → `up -d` → `sync-host`/`sync-net` → healthcheck de Odín, con evidencia de `/status` y logs
- [ ] TA-02 a TA-06: sondas por WAN, caída (< 2 min), degradación (< 5 min), quórum anti falso negativo y estado MQTT retained, cada uno ejecutado con evidencia
- [ ] TA-07 Sleipnir mide y alterna; techo de throughput calibrado por WAN y decisión sobre `THROUGHPUT_RECEIVER`
- [ ] TA-08 a TA-11: dashboard, percentiles, disponibilidad 30 d e indicador `apto_llamadas`
- [ ] TA-12 RNF01 (RAM ≤ 1.5 GB, CPU media < 10 %) medido 24 h; TA-13 RNF02 tras reinicio del appliance; TA-14 Recuperando → Saludable en 5 min
- [ ] TS-01 a TS-10: puertos desde LAN y desde WAN, login de Odín y Nornas, anónimo y ACL en Ratatosk, webhook sin Bearer, contenedores sin root, secretos fuera del repo, digests
- [ ] Matriz OWASP del PRD verificada: A01/A07 (login Grafana y Node-RED), A01 (Prometheus y Alertmanager no alcanzables), A05 (secretos), A06 (imágenes pineadas)
- [ ] Transiciones del `stateDiagram` de EnlaceWan verificadas, incluidas las inválidas (Caído → Saludable directo no ocurre)
- [ ] Riesgo conocido evaluado: inestabilidad USB del adaptador de `wan2` (resets del r8152) y su efecto en las pruebas
- [ ] **HITL**: Jeremi acepta los resultados, el techo calibrado y el residual; al aprobar, cortar `0.5.0`
