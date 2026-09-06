# ADR-0004: Frontera con Fenrir (Frigate NVR): proyecto independiente

* **Estado:** accepted
* **Fecha:** 2026-09-05
* **Decisores:** Jeremi
* **Fase AI-DLC:** 02-design
* **Versión:** 1.0.0
* **ID:** ADR-0004
* **Supersede / Superseded-by:** —
* **Controles OWASP afectados:** — (no añade superficie a Yggdrasil)

## Contexto
Gate 1 dejó pendiente confirmar el presupuesto de RAM del stack de monitoreo (RNF01, ≤ 1.5 GB) frente a la llegada de Frigate al mismo appliance (i3-3240, 8 GB). Frigate ya tiene su propio proyecto en la organización, `higerotech/nvr-frigate`, documentado bajo AI-DLC hasta Gate 5 y con métricas y monitoreo propios. El nombre **Fenrir** está reservado en `naming.md` para ese servicio dentro de Yggdrasil.

## Decisión
Fenrir (Frigate NVR) se implementa y opera desde el proyecto independiente `nvr-frigate`, incluidas sus métricas y su monitoreo. Yggdrasil no despliega Frigate ni absorbe su observabilidad en esta fase.
- El presupuesto de RAM de Yggdrasil queda fijado en ≤ 1.5 GB (RNF01) y no depende de Frigate; el presupuesto de Frigate se define y vigila en `nvr-frigate`.
- Los dos proyectos comparten el appliance. La coordinación de recursos se documenta en cada charter como restricción del host (8 GB de RAM, 456 GB de disco) y se revisa cuando cualquiera de los dos cambie su consumo.
- Una integración futura (federar métricas de Fenrir en Mimir, tableros conjuntos en Odín o reaccionar a sus eventos MQTT desde Nornas) se tratará como feature nueva de Yggdrasil con su PRD y su ADR; el contrato concreto (endpoint de métricas, tópicos `frigate/...`) se fijará entonces.

## Alternativas consideradas
| Opción | Pros | Contras | Riesgo de seguridad |
|---|---|---|---|
| Proyecto independiente (elegida) | Presupuestos y ciclos de vida desacoplados; `nvr-frigate` ya existe y avanza; Yggdrasil cierra Gate 1 sin dependencias externas | Dos stacks de observabilidad hasta que se integren; posible duplicidad de Prometheus/Grafana | Superficies separadas y acotadas |
| Absorber Frigate en Yggdrasil ahora | Un solo Compose y un solo Grafana | Mezcla NVR (vídeo, cámaras) con monitoreo SLA; RAM y alcance de Gate 1 se disparan | Más superficie dentro del mismo trust boundary |
| Yggdrasil como única observabilidad y `nvr-frigate` sin métricas propias | Evita duplicar Prometheus | Acopla el NVR a un proyecto aún en diseño y bloquea a `nvr-frigate` | Dependencia cruzada de despliegue |

## Consecuencias
- Positivas: Gate 1 queda sin dependencias externas; cada proyecto mide y presupuesta lo suyo; el nombre Fenrir sigue reservado para la integración futura.
- Negativas / deuda asumida: duplicidad temporal de piezas de observabilidad hasta la feature de integración; riesgo de contención de recursos si ambos proyectos crecen sin coordinar.
- Impacto en threat model: ninguno nuevo en Yggdrasil; la integración futura añadirá el endpoint de métricas de Frigate como superficie y requerirá su propio ADR.
- Condición de revisión: cuando `nvr-frigate` esté en producción (Gate 4/5) y se quiera un tablero único, abrir la feature de integración.
