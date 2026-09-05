# Glosario / Lenguaje Ubicuo (DDD)

* **Estado:** draft
* **Fecha:** 2026-09-01
* **Decisores:** Jeremi
* **Fase AI-DLC:** 00-project
* **Versión:** 0.1.0
* **Contextos acotados:** Observabilidad SLA, Domótica/Eventos

| Término | Definición | Contexto acotado (Bounded Context) |
|---|---|---|
| Enlace WAN | Conexión física/lógica a un ISP (`wan1` = ISP1, `wan2` = ISP2, cada una un UE300) | Observabilidad SLA |
| Sonda (probe) | Medición activa (ICMP/HTTP/speedtest) forzada a salir por una WAN concreta vía source IP | Observabilidad SLA |
| SLI | Indicador medido: latencia (percentiles p90, p95 y p99), pérdida %, jitter, Mbps, disponibilidad | Observabilidad SLA |
| SLO | Objetivo sobre un SLI, en ventana de 5 min: pérdida < 1 %, p95 < 500 ms para servicios estándar y p95 < 200 ms para llamadas críticas; throughput ≥ 800 Mbps por WAN (80 % del nominal). p90 y p99 se registran sin umbral, solo para seguimiento. Confirmados el 2026-09-05 | Observabilidad SLA |
| Estado del enlace | Saludable / Degradado / Caído / Recuperando, derivado de los SLO | Observabilidad SLA |
| Apto para llamadas | Indicador por WAN: `si` cuando p95 < 200 ms y pérdida < 1 % en 5 min; no altera el estado del enlace | Observabilidad SLA |
| Disponibilidad mensual | Fracción del tiempo, en ventana de 30 días, en que una WAN no estuvo Caída; la del hogar cuenta el tiempo con al menos una WAN operativa | Observabilidad SLA |
| Techo de medición | Throughput máximo que la cadena USB 3.0 (VL805/UE300) y el host pueden medir; límite del instrumento, no del ISP | Observabilidad SLA |
| Objetivo de sondeo | Host externo estable contra el que se mide (por defecto 1.1.1.1, 8.8.8.8 y `https://www.gstatic.com/generate_204`) | Observabilidad SLA |
| Alerta | Evento generado al violar un SLO, ruteado a notificación y publicado en `midgard/wan/<id>/alerta` | Observabilidad SLA |
| Tópico de estado | Tópicos MQTT retained `midgard/wan/<id>/estado`, `midgard/wan/<id>/apto_llamadas` y `midgard/hogar/internet/estado` que reflejan el estado de cada enlace y del hogar | Domótica/Eventos |
