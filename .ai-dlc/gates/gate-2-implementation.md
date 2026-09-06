# Gate 2 — Implementation (checklist)

* **Estado:** approved
* **Fecha:** 2026-09-05
* **Fase AI-DLC:** 03-implementation
* **Versión:** 0.1.0

> Adaptación: Heimdall es COTS configurado (blackbox_exporter, Prometheus, Alertmanager, Grafana)
> más dos piezas propias pequeñas (script de Sleipnir y flujo de Nornas). El equivalente a
> "SAST limpio + deps verificadas + 80 % cobertura" es **configuración validada + cadena de
> suministro verificada + historial versionado**. Artefactos: `deploy/` y `docs/03-implementation/`.

- [x] `deploy/docker-compose.yml`: imágenes pineadas, `mem_limit` dentro de RNF01 (1088 MB), `restart` (RNF02), host-mode solo en sondas y sin puertos internos publicados (ADR-0003), Grafana ligada a la IP LAN (RS01)
- [x] Configuraciones del contrato: blackbox (módulos ICMP y TLS por WAN), Prometheus (scrape 15 s, recording rules `wan:*`/`hogar:*`, alertas `WanCaida`, `WanDegradada`, `WanNoAptaLlamadas`, `WanThroughputBajo`), Alertmanager (rutas, inhibición, webhook Bearer), Grafana (datasource + dashboard comparativo), Sleipnir (Dockerfile + script), flujo de Nornas
- [x] Plantillas renderizadas por `scripts/render.sh`; secretos e IPs solo en `.env` y en los renderizados, todos gitignored
- [x] Validación de config (equivale a SAST), verde en local y en CI (PR #7, 2026-09-05): `docker compose config`, `promtool check config/rules`, `amtool check-config`, `blackbox --config.check`, JSON del dashboard y del flujo, ShellCheck — local y en CI (`validar-configs.yml`)
- [x] Cadena de suministro (A03): digests en `deploy/imagenes.md`; informe Trivy revisado y triado en `docs/03-implementation/cadena-suministro.md` (imágenes re-pineadas a las releases parcheadas de 2026; residual documentado)
- [x] Secretos (A02): gitleaks limpio en CI (PR #7); `.env` y renderizados ignorados
- [x] `docs/03-implementation/` con notas de implementación (desviaciones respecto a Gate 1: TLS en vez de HTTP 204, token Bearer, Sleipnir por httpd, RTT de `probe_icmp_duration_seconds`, puertos en docker0) y `repo-history.md` derivado con `gitgraph_from_log.py`
- [x] Contratos de `architecture.md`, threat model (T4), hosts del PRD, glosario y ADR-0003 actualizados con esas desviaciones
- [x] **HITL** (2026-09-05): Jeremi acepta la política de triaje y el residual de `cadena-suministro.md` y las desviaciones documentadas

**Gate 2 cerrado el 2026-09-05.** Versión `0.3.0` en CHANGELOG; tag `v0.3.0` en `main`. Siguiente: Gate 3 (Testing) → `0.4.0`: despliegue en el appliance, pruebas de aceptación de RF01–RF09, calibración del techo de throughput y prueba de carga de las sondas.
