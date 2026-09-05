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
| SLI | Indicador medido: latencia p95, pérdida %, jitter, Mbps, disponibilidad | Observabilidad SLA |
| SLO | Objetivo sobre un SLI (p. ej. pérdida < 1% en ventana de 5 min) | Observabilidad SLA |
| Estado del enlace | Saludable / Degradado / Caído / Recuperando, derivado de los SLO | Observabilidad SLA |
| Objetivo de sondeo | Host externo estable contra el que se mide (1.1.1.1, 8.8.8.8, endpoint HTTP) | Observabilidad SLA |
| Alerta | Evento generado al violar un SLO, ruteado a notificación | Observabilidad SLA |
| Tópico de estado | Tópico MQTT `midgard/wan/<id>/estado` que refleja el estado del enlace | Domótica/Eventos |
