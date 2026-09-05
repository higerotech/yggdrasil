# Convención de nombres — Yggdrasil

* **Estado:** approved
* **Fecha:** 2026-09-01
* **Decisores:** Jeremi
* **Fase AI-DLC:** 00-project
* **Versión:** 0.1.0
* **Tema:** Mitología nórdica (sucesor espiritual de Centinela)

## Regla
Cada servicio recibe un nombre del universo nórdico cuya función mitológica refleje su función técnica. El nombre técnico real siempre va en el slot de tecnología del C4 y en los `container_name` de Compose, para que el diagrama sea legible por terceros.

## Topología de mundos
| Mundo | Rol en la plataforma |
|---|---|
| **Yggdrasil** | La plataforma completa (el árbol que conecta todos los mundos) |
| **Midgard** | Tier edge: el appliance en la pared (captura y datos crudos) |
| **Asgard** | Tier nube (futuro): dashboards y notificaciones escalables |
| **Bifrost** | El puente edge ↔ nube (hoy WireGuard) |

## Servicios actuales (F-001 Heimdall)
| Nombre | Tecnología | Función mitológica → técnica |
|---|---|---|
| **Heimdall** | Servicio Monitor SLA (conjunto) | El guardián del Bifrost que ve a cien leguas → vigila los dos enlaces WAN |
| **Huginn** y **Muninn** | Módulos blackbox_exporter (wan1/wan2) | Los cuervos de Odín que salen cada día y vuelven con noticias → sondas ICMP/HTTP por WAN |
| **Sleipnir** | Sonda de throughput (speedtest/iperf3) | El caballo de ocho patas, el más veloz → mide la velocidad real |
| **Mimir** | Prometheus (TSDB + reglas) | El pozo de la sabiduría y la memoria → guarda y evalúa las métricas |
| **Gjallarhorn** | Alertmanager | El cuerno de Heimdall que suena cuando algo amenaza → alertas |
| **Odín** | Grafana | Desde su trono ve todos los mundos → dashboards |
| **Nornas** | Node-RED | Tejen el destino a partir de los hilos → automatización sobre eventos |
| **Ratatosk** | Mosquitto (MQTT) | La ardilla mensajera que recorre Yggdrasil → bus de eventos |

## Espacio de tópicos MQTT
Prefijo por mundo: `midgard/...` para lo generado en el edge (p. ej. `midgard/wan/wan1/estado`), reservado `asgard/...` para el tier nube.

## Nombres reservados (futuros servicios)
| Nombre | Candidato para |
|---|---|
| **Fenrir** | Frigate NVR (el lobo vigilante) |
| **Loki** | Agregación de logs (coincide con Grafana Loki) |
| **Thor** | Métricas del host / node_exporter (la fuerza de la máquina) |
| **Freyja** | Sensores IoT / Home Assistant si llegara |
| **Valhalla** | Archivo frío / respaldos de largo plazo |

Nota feliz: el ecosistema Grafana ya usa nombres nórdicos (Loki, Mimir), así que futuras adopciones encajan en el tema sin fricción.
