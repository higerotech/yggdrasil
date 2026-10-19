# Threat Model — Monitor SLA de Internet

* **Estado:** approved
* **Fecha:** 2026-09-01
* **Decisores:** Jeremi
* **Fase AI-DLC:** 02-design
* **Versión:** 0.2.0 (revisión 2026-10-19, al pie)
* **Gate:** 1
* **Alcance:** Servicio Monitor SLA (sondas, TSDB, dashboards, puente MQTT), tablero de pared, métricas del host (Thor), despliegue continuo, respaldo y avisos
* **Metodología:** STRIDE + DREAD
* **Clasificación de datos (ref):** `docs/00-project/data-classification.md`

## Diagrama de flujo de datos (DFD)
```mermaid
flowchart LR
    INET([Internet / objetivos de sondeo])
    subgraph TBH [Trust boundary: appliance - red interna Docker]
      BB[Huginn y Muninn - host mode] --> PROM[(Mimir TSDB)]
      SPD[Sleipnir - throughput] --> PROM
      PROM --> AM[Gjallarhorn]
      AM --> NR[Nornas]
      TH[Thor - httpd ro] --> PROM
      SY[sync-host - escribe el clon] -.-> CL[(Clon del repo)]
    end
    subgraph TBHOST [Trust boundary: host midgard]
      HS[yggdrasil-thor.sh y respaldo] -->|host.prom| TH
    end
    NAS[(NAS de respaldos - lleva secretos)]
    NTFY([ntfy - el tema es la credencial])
    HS -->|archivo diario, 700/600| NAS
    HS -->|avisos| NTFY
    NR -->|push| NTFY
    TAB([Tablet Hlidskjalf]) -->|token de lectura| NR
    subgraph TBL [Trust boundary: LAN]
      GF[Odín - Grafana]
      MQ[[Ratatosk MQTT]]
      IOT([Dispositivos IoT no confiables])
    end
    BB -->|ICMP y TCP+TLS por wan1 y wan2| INET
    GF -->|PromQL solo via red interna| PROM
    NR -->|estado retained| MQ
    IOT -.->|suscripcion autenticada| MQ
    ADM([Administrador]) -->|HTTPS LAN o WireGuard| GF
```
*Eje comportamiento (DFD) · fase 02 · insumo del STRIDE.*

## Análisis STRIDE
| Componente | Spoofing | Tampering | Repudiation | Info Disclosure | DoS | Elevation |
|---|---|---|---|---|---|---|
| Grafana | Login por defecto débil → credenciales fuertes, sin anónimo | Edición de dashboards → roles | Logs de acceso activos | Métricas de presencia → solo LAN/WG | Rate limit implícito LAN | Sin plugins no firmados |
| Prometheus | — | Escritura/borrado TSDB → puerto no publicado | — | API abierta → solo red interna | Cardinalidad de labels acotada | Contenedor no-root |
| Blackbox (host) | Objetivos suplantados (DNS) → objetivos por IP + HTTPS | Config de módulos → volumen ro | — | — | Frecuencia de sondas acotada | `nobody` con `cap_drop: [ALL]`; ICMP por `ping_group_range` (v0.4.8) |
| Alertmanager → Node-RED | Webhook falso → token Bearer en cabecera Authorization, solo por la red interna de Compose | Payload manipulado → validación en flujo | — | — | Agrupación/inhibición configuradas | — |
| MQTT (Ratatosk, 1883 en la IP LAN) | Cliente anónimo → `allow_anonymous false`, credencial por cliente (`nornas`, `iot`) | Publicar estado falso → ACL: solo `nornas` escribe `midgard/#` (ADR-0006) | — | Suscripción abierta → ACL de lectura por usuario | Flood → `max_connections`, `max_queued_messages`, `message_size_limit` | Contenedor con rootfs de solo lectura |
| Node-RED (Nornas, editor 1880 en la IP LAN) | Editor sin login → `adminAuth` obligatorio con bcrypt | Flujos alterados → solo administradores autenticados | Auditoría del runtime activada | — | LAN/WireGuard únicamente | Sin `require` dinámico en functions; paleta instalable solo por admin (riesgo aceptado) |

## Amenazas priorizadas (DREAD)
```mermaid
quadrantChart
    title DREAD priorizado — Monitor SLA
    x-axis Baja probabilidad --> Alta probabilidad
    y-axis Bajo impacto --> Alto impacto
    quadrant-1 Atender ya
    quadrant-2 Monitorear
    quadrant-3 Aceptar
    quadrant-4 Planear
    Grafana credenciales debiles: [0.6, 0.8]
    API Prometheus expuesta a LAN: [0.5, 0.7]
    Estado falso publicado en MQTT: [0.4, 0.6]
    Webhook AM sin token: [0.5, 0.5]
    Speedtest satura enlace: [0.7, 0.3]
```

| ID | Amenaza | D | R | E | A | D | Score | Control / ADR |
|---|---|---|---|---|---|---|---|---|
| T1 | Acceso a Grafana con credenciales por defecto | 7 | 9 | 8 | 5 | 7 | 7.2 | Password fuerte + sin anónimo (RS01) |
| T2 | API de Prometheus alcanzable desde la LAN/IoT | 6 | 8 | 7 | 5 | 6 | 6.4 | No publicar 9090; solo red interna (ADR-0003) |
| T3 | Dispositivo IoT publica estado falso en `midgard/wan/#` | 6 | 6 | 5 | 4 | 5 | 5.2 | ACL de Ratatosk por usuario/tópico, control propio desde ADR-0006 |
| T4 | Webhook Alertmanager→Node-RED falsificado | 5 | 6 | 5 | 4 | 5 | 5.0 | Token Bearer en cabecera + validación en flujo (implementado en Gate 2; el token no queda en logs de acceso) |
| T5 | Sonda de throughput degrada el servicio del hogar | 4 | 8 | 6 | 6 | 3 | 5.4 | Cada WAN cada 6 h (Sleipnir mide cada 3 h alternando), ~70 s por medición; Hlidskjalf y las reglas descuentan la pérdida que provoca. El «horario valle» previsto en Gate 1 no se implementó |
| T6 | Lectura del estado de midgard por `/hlidskjalf/resumen` desde la LAN (patrones de presencia) | 3 | 7 | 5 | 4 | 5 | 4.8 | Token de solo lectura propio (`HLIDSKJALF_TOKEN`, ≥ 32 caracteres, comparación en tiempo constante); sin token, 503; solo LAN, sin puerto nuevo; la página escapa todo texto y lleva CSP por hash (ADR-0007) |

| T7 | `sync-host` escribe en el clon del repo (bind mount `..:/repo`): un contenedor comprometido podría alterar el código que se despliega | 3 | 8 | 4 | 3 | 4 | 4.4 | Contenedor de un solo uso como el usuario `deploy` (no root), rootfs de solo lectura y `no-new-privileges`; hace checkout del commit `IMAGE_TAG`, que fija el receptor a partir del webhook firmado (ADR-0005). Corre en host-mode (necesita ver las WAN para el render), así que tiene red. **Propuesto, pendiente de HITL** |
| T8 | Archivo de respaldo en el NAS: lleva el `.env` y la configuración renderizada (secretos) | 3 | 9 | 4 | 3 | 4 | 4.6 | Directorio 700 y ficheros 600; el export `respaldos` solo admite a midgard; retención 14 días. **Propuesto, pendiente de HITL** |
| T9 | El tema de ntfy es la credencial: quien lo conozca lee los avisos (incluidas caídas y respaldos) | 4 | 6 | 7 | 3 | 4 | 4.8 | Tema aleatorio en `/etc/yggdrasil-aviso.env` y en `.env` (600), fuera del repo; un solo fichero que rotar. **Propuesto, pendiente de HITL** |
| T10 | Datos del host (Thor): número de serie de los discos e inventario de servicios | 2 | 4 | 4 | 3 | 3 | 3.2 | La salida de `smartctl` se guarda en `/var/cache/yggdrasil-thor` (0700), fuera de lo que se sirve; el contenedor monta el directorio en solo lectura y no publica puerto. **Propuesto, pendiente de HITL** |

## Controles y trazabilidad
- T1 → RS01 (PRD) · ASVS V2 · verificación por inspección en Gate 3.
- T2, T4 → ADR-0003 (topología de red de contenedores) · ASVS V13.
- T3 → `deploy/mosquitto/acl` (Ratatosk, ADR-0006) — control propio de la plataforma.
- T5 → RF02 y regla de scheduler — verificación por test de carga en Gate 3.
- T6 → ADR-0007 · `deploy/nornas/tests/hlidskjalf.test.mjs` (401/503, escape de HTML, CSP). T2 se mantiene: el tablero consulta Mimir y Gjallarhorn desde Nornas, por la red interna, sin publicarlos.
- T7 → ADR-0005 · `deploy/docker-compose.cd.yml`. T8 → `deploy/cd/README.md` (respaldo al NAS). T9 →
  `deploy/cd/README.md` (avisos por ntfy) y `data-classification.md`. T10 → `deploy/cd/README.md` (Thor).

> **Revisión 2026-10-19 — coherencia con la v0.5.13** (auditoría documental).
> - El DFD y el alcance suman Thor, el respaldo al NAS, ntfy, la tablet y la tarea `sync-host`.
> - Se proponen T7 a T10, con sus puntuaciones DREAD pendientes de que Jeremi las confirme. T7 es
>   la amenaza que ADR-0005 llamaba «T6».
> - Blackbox ya no lleva `NET_RAW` (v0.4.8).
> - Ratatosk ya no tiene el cliente `frigate` (0.5.3).
> - T5 deja de prometer un horario valle que nunca se implementó.
