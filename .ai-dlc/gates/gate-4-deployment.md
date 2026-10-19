# Gate 4 — Deployment (checklist)

* **Estado:** en curso
* **Fecha:** 2026-10-19
* **Fase AI-DLC:** 05-deployment
* **Versión:** 0.6.0 (prevista al cierre)

> Adaptación: Yggdrasil **ya opera en producción** desde la `v0.4.0` (2026-09-05), cuando el
> despliegue continuo (ADR-0005) llevó el stack a midgard y su primer despliegue fue la prueba
> TA-01 de Gate 3. Desde entonces han entrado 23 releases más por el mismo camino (build → GHCR →
> webhook firmado → receptor → `up -d` → healthcheck → rollback), sin que la fase 05 tuviera
> documento ni gate. Este gate no decide *si* se despliega: formaliza *cómo* se despliega, qué
> controles tiene el pipeline y qué falta para que la operación sea recuperable y no solo
> automática. Artefactos: `docs/05-deployment/deployment.md`, `docs/04-testing/inventario-pruebas.md`
> y las correcciones de la auditoría documental del 2026-10-19. El cierre corta `0.6.0`
> (`CHANGELOG.md`, nota de versionado de la 0.5.4).

- [x] **Despliegue continuo en producción**: receptor de `despliegue-continuo` con `rollback: true`, `health_url` de Odín y `health_timeout: 300` (`deploy/cd/apps.yggdrasil.yml`); 24 tags desplegados de `v0.4.0` a `v0.5.13` (`git tag`); TA-01 superado el 2026-09-06 (`docs/04-testing/test-plan.md:218-223`)
- [x] **C4 Deployment, flowchart del pipeline con rollback y cronología del cutover** redactados en `docs/05-deployment/deployment.md` (§1, §2, §4), leídos de los workflows, `deploy/cd/` y `deploy/sync/sync.sh`; diagramas validados con `validate_mermaid.py`. Pendiente de pasar a `approved` en el HITL
- [x] **Inventario completo de pruebas** (`docs/04-testing/inventario-pruebas.md`): 5 jobs de CI, 3 ficheros de `promtool test rules`, `intervalos.py`, 2 suites de Node (15 + 23 pruebas), 6 pruebas bash con dobles, build del APK, gitleaks, Trivy en modo informe, pruebas manuales vigentes y sección de huecos
- [x] **Arranque tras corte de corriente**: `yggdrasil-arranque.service` instalada por `bootstrap-midgard.sh` (paso 5b) y verificada con el corte real del 2026-09-08 23:17 UTC (TA-13, `test-plan.md:291-304`)
- [x] **Respaldo nocturno instalado** con verificación de suma y avisos: `yggdrasil-respaldo.timer` (22:30 Caracas, `Persistent=true`), 14 archivos en el NAS, `OnFailure=` y vigía de las 08:00 (`deploy/cd/README.md:113-161`, v0.5.6); `RespaldoAtrasado` en Thor (v0.5.12)
- [x] **Vigilancia de la propia cadena de despliegue y de alertas**: vigía de servicios cada minuto directo a ntfy (contenedores permanentes y `cd-receiver`, `docker`, temporizadores), 22 comprobaciones con dobles en CI (`deploy/cd/tests/prueba-vigia-servicios.sh`); Thor publica `yggdrasil_servicio_ok` para el tablero
- [x] **Secretos fuera del pipeline y del repo**: gitleaks bloqueante sobre todo el historial (`validar-configs.yml:118-127`); `.env`, renderizados y `.sync/` gitignored; token del webhook en cabecera (TS-08)
- [x] **Runbook de rollback y recuperación escrito** (`deployment.md` §3): rollback automático, relanzar el build del commit bueno, hotfix por GitFlow, contingencia con `deploy.sh`, restauración desde el NAS, arranque tras corte, actualización de lo que el receptor no despliega
- [ ] **Runbook de rollback probado**: provocar un despliegue que agote el healthcheck con `previous_tag` registrado y comprobar que el receptor vuelve al tag anterior y que `sync-host` hace checkout de ese commit (en TA-01 el healthcheck se agotó sin tag previo y no hubo rollback real)
- [ ] **Restauración desde el respaldo ensayada**: ejecutar el procedimiento de `deployment.md` §3.3 al menos una vez (en midgard con el stack parado, o en una máquina de prueba con un archivo real del NAS) y anotar tiempo y resultado
- [ ] **Pipeline con los 7 controles de seguridad decididos**: hoy bloquean SAST-equivalente y secretos; SCA, contenedores e IaC están en modo informe (Trivy `--exit-code 0`); licencias y DAST no existen (`deployment.md` §5). Decisión HITL sobre cuáles se exigen y, para los que sí, implementar el filtro (`.trivyignore` con caducidad por CVE aceptado, punto 5 de `docs/03-implementation/cadena-suministro.md`, pendiente desde Gate 2)
- [ ] **IaC/Compose escaneado con bloqueo**: Trivy `config` sobre `deploy/` con `--exit-code 1` una vez triado el informe actual; escanear también las imágenes propias construidas
- [ ] **Jitter de RF01 implementado y probado** (decisión HITL del 2026-10-19): recording rule `wan:jitter_ms:5m` (desviación típica del RTT ICMP en 5 min por objetivo, mediana de los objetivos de cada WAN) y el jitter de Ookla publicado por Sleipnir; contrato en `architecture.md`, panel en Odín, caso en `promtool test rules` y entrada en `inventario-pruebas.md`
- [ ] **Correcciones de la auditoría documental del 2026-10-19** fusionadas: `architecture.md` (C4 con Thor y sondas del hogar, objetivos y quórum reales, tabla de alertas completa, payload MQTT), PRD y charter (SLO de alertado aceptado en Gate 3, intervalos reales, hosts, «existentes»), ADR-0002/0004/0006 (superseded y revisiones), threat model y clasificación de datos (respaldo en NAS, ntfy, Thor, bind mount de sync), `naming.md` (Bifröst, Hermod, Andvari, Sleipnir), `deploy/README.md`, `deploy/cd/README.md`, `.env.example` (`THROUGHPUT_RECEIVER`), sumas de `mem_limit` y RAM de TA-12, `repo-history.md` regenerado
- [ ] **Panel de throughput de Odín con el SLO por WAN y dirección** (`wan:slo_throughput_mbps`) en lugar del umbral fijo de 800 (hallazgo de la auditoría; hoy la subida de wan2 en objetivo se pinta en rojo)
- [ ] **`SondaCaida` cubre las sondas del hogar** (`hogar_icmp`, `hogar_tls`) y tiene caso en `promtool test rules`
- [ ] **Deriva de las unidades del host**: decidir cómo llega a midgard un cambio en `deploy/cd/*.sh`, `deploy/cd/*.service|timer` o `deploy/host/` fusionado en `main` (hoy exige ejecutar a mano `bootstrap-midgard.sh` o `install-host.sh` y nada avisa), o al menos documentar la comprobación tras cada release que los toque
- [ ] **Detección en operación de T7-T10** (`threat-model.md`): Thor publica `yggdrasil_clon_coherente`, `yggdrasil_respaldo_permisos_ok`, `yggdrasil_aviso_tema_edad_dias` y `yggdrasil_thor_cache_permisos_ok`, con las alertas `ClonAlterado`, `RespaldoPermisosAbiertos` y `ThorCacheExpuesta` y sus casos en `prueba-thor.sh` y `promtool test rules`; DREAD revisado con 30 días de datos
- [ ] **TS-02 desde fuera de la red** (`nmap` desde datos móviles contra la IP pública de cada WAN), pendiente desde Gate 3 (`test-plan.md:339`)
- [ ] **Verificación tras despliegue repetible**: dejar por escrito (o en un script) la comprobación de `deployment.md` §3.1 como paso obligatorio de cada release, incluido el log de `sync-host`, que el healthcheck no mira
- [ ] **HITL**: Jeremi acepta el runbook, los controles exigidos y el residual (controles en modo informe o inexistentes, riesgos abiertos de `deployment.md` §6); `deployment.md` e `inventario-pruebas.md` pasan a `approved` y se corta `0.6.0`
