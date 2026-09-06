# Gate 2 — Implementation (checklist)

* **Estado:** draft
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
- [ ] Validación de config (equivale a SAST): `docker compose config`, `promtool check config/rules`, `amtool check-config`, `blackbox --config.check`, JSON del dashboard y del flujo, ShellCheck — local y en CI (`validar-configs.yml`)
- [ ] Cadena de suministro (A03): digests anotados en `deploy/imagenes.md`; informe Trivy revisado; CVEs CRITICAL/HIGH triados
- [ ] Secretos (A02): gitleaks limpio en CI; `.env` y renderizados ignorados
- [ ] `docs/03-implementation/` con notas de implementación (desviaciones respecto a Gate 1: TLS en vez de HTTP 204, token Bearer, Sleipnir por httpd, RTT de `probe_icmp_duration_seconds`, puertos en docker0) y `repo-history.md` derivado con `gitgraph_from_log.py`
- [ ] Contratos de `architecture.md` y hosts del PRD actualizados con esas desviaciones
- [ ] **HITL**: Jeremi acepta los CVEs residuales y las desviaciones documentadas

Al aprobar: cortar `0.3.0` vía `release/0.3.0`.
