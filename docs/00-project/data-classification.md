# Clasificación de Datos

* **Estado:** approved
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
| Credenciales (Grafana, MQTT por cliente, editor de Node-RED, token del webhook) | Restringido | — | Sí (`.env` 600; passwd de Mosquitto generado en el volumen; credenciales de flujos cifradas) | LAN/WireGuard | Hasta rotación |
| Token de lectura del tablero de pared (`HLIDSKJALF_TOKEN`) | Restringido | — | Sí (`.env` 600; en la tablet, datos privados de la app) | LAN/WireGuard | Hasta rotación |
| Resumen del tablero de pared (estado de WAN, alertas, host y servicios) | Interno | — | No (no se guarda; la tablet solo lo pinta) | LAN | No se retiene |
| Patrones de uso/presencia derivables de tráfico | Confidencial | — | No | LAN/WireGuard | Implícita en métricas |

Niveles: Público < Interno < Confidencial < Restringido.

Nota: las métricas agregadas de WAN pueden revelar patrones de presencia en casa; no exponerlas fuera de LAN/WireGuard.
