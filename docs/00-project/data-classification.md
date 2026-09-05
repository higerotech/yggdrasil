# Clasificación de Datos

* **Estado:** draft
* **Fecha:** 2026-09-01
* **Decisores:** Jeremi
* **Fase AI-DLC:** 00-project
* **Versión:** 0.1.0
* **Owner de datos (DPO):** Jeremi
* **Regulación aplicable:** Ninguna formal (uso doméstico); criterio de privacidad del hogar

| Dato | Clasificación | Regulación | Cifrado en reposo | Cifrado en tránsito | Retención |
|---|---|---|---|---|---|
| Métricas de red (latencia, pérdida, Mbps por WAN) | Interno | — | No (disco local) | TLS solo en acceso remoto (WireGuard) | 30 días |
| IPs públicas asignadas por cada ISP | Confidencial | — | No | WireGuard | 30 días |
| Credenciales (Grafana, MQTT) | Restringido | — | Sí (secrets/env con permisos 600) | TLS/WireGuard | Hasta rotación |
| Patrones de uso/presencia derivables de tráfico | Confidencial | — | No | LAN/WireGuard | Implícita en métricas |

Niveles: Público < Interno < Confidencial < Restringido.

Nota: las métricas agregadas de WAN pueden revelar patrones de presencia en casa; no exponerlas fuera de LAN/WireGuard.
