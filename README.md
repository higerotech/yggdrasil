# Yggdrasil

Plataforma demo de IoT y domótica sobre el appliance doméstico (Ubuntu Server 24.04, Mini-ITX en pared)
que monitorea los servicios de la casa. El primer servicio es **Heimdall**, el monitor de niveles de
servicio (SLA) de los dos proveedores de internet: latencia, pérdida, jitter, throughput y
disponibilidad por cada WAN, con dashboards, alertas y estado publicado en MQTT.
Documentación bajo metodología AI-DLC.

## Estado del proyecto

| Fase | Artefactos | Gate | Estado |
|---|---|---|---|
| 00-project | charter, glosario, clasificación de datos, convención de nombres | — | draft (naming: approved) |
| 01-requirements | PRD F-001 Heimdall | Gate 0 | review — validación humana pendiente |
| 02-design | arquitectura C4, threat model STRIDE+DREAD, ADR-0001..0003 | Gate 1 | review — validación humana pendiente |

Pendientes de decisión humana antes de cerrar los gates: umbrales SLO (pérdida 1 %, p95) y
objetivos de sondeo definitivos (Gate 0); aceptar ADR-0001 y ADR-0003 y confirmar el presupuesto
de RAM con Frigate futuro (Gate 1). Al aprobar cada gate se corta la versión correspondiente en
`CHANGELOG.md` (Gate 0 → 0.1.0, Gate 1 → 0.2.0).

## Mapa del repo

- `docs/00-project/` — charter, glosario (lenguaje ubicuo), clasificación de datos y `naming.md`
- `docs/01-requirements/` — PRD `isp-sla-monitor.md` con escenarios de abuso, C4 Context, journey y trazabilidad (Gate 0)
- `docs/02-design/` — `architecture.md` (C4 Container, sequence, state, ER, class, contratos), `threat-model.md` y `adr/` (Gate 1)
- `docs/gates/` — checklists de los Gates 0 y 1
- `.github/workflows/` — guardia de GitFlow para los PR hacia `main`
- `CHANGELOG.md` — Keep a Changelog 1.1.0 + SemVer 2.0.0
- `LICENSE` — GNU Affero General Public License v3.0

## Nombres de los servicios

Cada servicio lleva un nombre de la mitología nórdica cuya función refleja la técnica; el nombre
real de la tecnología va siempre en el slot de tecnología del C4 y en los `container_name` de
Compose. La regla completa, la topología de mundos (Midgard edge, Asgard nube, Bifrost puente) y
los nombres reservados están en `docs/00-project/naming.md`.

| Nombre | Tecnología | Función |
|---|---|---|
| Heimdall | Servicio Monitor SLA (conjunto) | Vigila los dos enlaces WAN |
| Huginn y Muninn | blackbox_exporter (wan1 / wan2) | Sondas ICMP/HTTP por WAN |
| Sleipnir | speedtest / iperf3 | Throughput periódico |
| Mimir | Prometheus | TSDB y reglas SLO |
| Gjallarhorn | Alertmanager | Alertas |
| Odín | Grafana | Dashboards |
| Nornas | Node-RED | Automatización sobre eventos |
| Ratatosk | Mosquitto (MQTT) | Bus de eventos (`midgard/...`) |

## Anonimización

Este repositorio es público y documenta la postura de seguridad de una casa concreta, así que
**ningún dato real del despliegue vive en él**. Los únicos hosts que aparecen en la documentación
son objetivos públicos de sondeo (1.1.1.1, 8.8.8.8). Cuando lleguen los artefactos ejecutables
(`deploy/`), aplica la misma convención que el resto de repos del estándar:

| Dato real | Dónde vive | Cómo aparece en el repo |
|---|---|---|
| IPs de `wan1` / `wan2` y del appliance | `.env` (600, gitignored) | `${WAN1_IP}`, `${WAN2_IP}` |
| Credenciales de Grafana y MQTT | `.env` y ficheros de password (gitignored) | `CAMBIAR` |
| IPs públicas asignadas por cada ISP | Solo en la TSDB local | No aparecen |

Los valores de ejemplo usan `192.0.2.0/24`, el rango que RFC 5737 reserva para documentación.

## Flujo de trabajo (GitFlow)

| Rama | Rol | Origen | Destino |
|---|---|---|---|
| `main` | Solo releases; cada merge lleva tag `vX.Y.Z` alineado con `CHANGELOG.md` | — | — |
| `develop` | Integración (rama por defecto del repo) | `main` | — |
| `feature/*` | Trabajo diario | `develop` | PR → `develop` |
| `release/X.Y.Z` | Cierre de un gate / versión | `develop` | PR → `main`, tag, back-merge a `develop` |
| `hotfix/X.Y.Z` | Corrección urgente sobre lo publicado | `main` | PR → `main`, tag, back-merge a `develop` |

`main` está protegida por un ruleset del repositorio: no admite push directo, borrado ni
force-push; solo se actualiza por pull request con merge commit, y el check
**GitFlow: origen permitido hacia main** (`.github/workflows/gitflow-guard.yml`) falla si la rama
de origen no es `develop`, `release/*` o `hotfix/*`, o si viene de un fork.

Para usar la CLI `git flow` (AVH) con esta configuración:

```bash
git config gitflow.branch.master main
git config gitflow.branch.develop develop
git config gitflow.prefix.feature feature/
git config gitflow.prefix.release release/
git config gitflow.prefix.hotfix hotfix/
git config gitflow.prefix.versiontag v
git flow init -d
```

## Despliegue

Según ADR-0002, todo el stack corre en el appliance con Docker Compose y GitHub Actions se limita
a lint y validación de configuraciones; no hay pipeline push hacia la red doméstica. El despliegue
es un `git pull` seguido de `docker compose up -d` mediante un script idempotente, cuando existan
los artefactos en `deploy/`.

## Licencia

Este proyecto se distribuye bajo la **GNU Affero General Public License v3.0** (`AGPL-3.0`); el
texto completo está en `LICENSE`. Si despliegas una versión modificada que otros usen a través de
la red, la AGPL obliga a ofrecerles el código fuente correspondiente.
