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

- [x] TA-01 Despliegue continuo (2026-09-06, tercer intento): build → GHCR → webhook → receptor → `up -d` → `sync-host`/`sync-net` → healthcheck de Odín `200`; evidencia en `test-plan.md`. Hallazgos por el camino: paquetes GHCR privados por defecto y primer arranque de Grafana de ~3 min
- [x] TA-02 a TA-06: sondas por WAN, caída (< 2 min), degradación (< 5 min), quórum anti falso negativo y estado MQTT retained, cada uno ejecutado con evidencia — **hechos el 2026-09-08** (evidencia en `test-plan.md`); latencias medidas 2 m 18–46 s y ≈ 6 min (decisión HITL sobre `for`); TA-05 destapó la regla de pérdida (v0.4.6)
- [x] TA-07 Sleipnir mide y alterna; techo de throughput calibrado por WAN y decisión sobre `THROUGHPUT_RECEIVER` (2026-09-08): techo de la cadena ≥ 939 Mbps; `speedtest-cli` descartado y Sleipnir en la CLI de Ookla contra tres servidores (v0.4.3–v0.4.5); lecturas en producción 967/941 (wan1) y 941/487 (wan2); `THROUGHPUT_RECEIVER=nornas` armado a las 00:48 UTC. Evidencia en `test-plan.md`
- [x] TA-08 a TA-11: dashboard, percentiles, disponibilidad 30 d e indicador `apto_llamadas` — **hechos el 2026-09-08**
- [ ] TA-12 RNF01 (RAM ≤ 1.5 GB, CPU media < 10 %) medido 24 h; TA-13 RNF02 tras reinicio del appliance; TA-14 Recuperando → Saludable en 5 min — TA-12 en curso (24 h desde 2026-09-08 01:02 UTC); TA-13 pendiente de HITL (reinicio); TA-14 hecho (hallazgos → v0.4.7) — TA-14 hecho (hallazgos → v0.4.7). **TA-13 superado**: falló en el reinicio de las 12:12 (Gjallarhorn no volvió), se corrigió con `yggdrasil-arranque.service` (v0.4.9) y la repetición llegó sola en el corte de corriente de las 23:17, con los siete servicios de vuelta y la unidad confirmando la convergencia. TA-12 en curso con un hueco de 27 min por el propio reinicio
- [x] TS-01 a TS-10: puertos desde LAN y desde WAN, login de Odín y Nornas, anónimo y ACL en Ratatosk, webhook sin Bearer, contenedores sin root, secretos fuera del repo, digests — **hechos el 2026-09-08**; TS-02 con evidencia indirecta (nmap desde datos móviles pendiente de HITL); TS-07 destapó blackbox como root → v0.4.8
- [x] Matriz OWASP del PRD verificada: A01/A07 (login Grafana y Node-RED), A01 (Prometheus y Alertmanager no alcanzables), A05 (secretos), A06 (imágenes pineadas) — verificada con TS-03/06 (A01/A07), TS-04/10 (A01), TS-08 (A05), TS-09 (A06), TS-07 (elevación)
- [x] Transiciones del `stateDiagram` de EnlaceWan verificadas, incluidas las inválidas (Caído → Saludable directo no ocurre) — **verificadas el 2026-09-08**: Saludable → Degradado (TA-04, TA-11), Degradado → Caído (TA-03), Caído → Recuperando → Degradado/Saludable (TA-14); Caído → Saludable directo no ocurrió
- [x] Riesgo conocido evaluado: inestabilidad USB del adaptador de `wan2` (resets del r8152) y su efecto en las pruebas — **evaluado el 2026-09-08**: con el adaptador sustituido el 2026-09-06, en 2 días y 7 h de servicio el kernel no registró ningún reset ni desconexión del r8152 (el único evento es el `carrier on` de la propia prueba TA-03); `wan2` acumula 0 errores de transmisión y 24 descartes de recepción. El adaptador anterior daba 51 eventos en 20 min. El riesgo no afectó a la tanda de aceptación, **pero reapareció en el reinicio de TA-13**: en el arranque de las 12:15 UTC el kernel registró `NETDEV WATCHDOG` en `wan2` con la cola de transmisión bloqueada 71–82 s y el enlace no se recuperó solo; en el arranque siguiente `wan2` funciona sin pérdida. El adaptador es estable en marcha, pero la enumeración USB del arranque puede dejarlo colgado. Riesgo **aceptado con vigilancia**: `WanCaida` lo detecta y el hogar mantiene servicio por la otra WAN
- [ ] **HITL**: Jeremi acepta los resultados, el techo calibrado y el residual; al aprobar, cortar `0.5.0`
