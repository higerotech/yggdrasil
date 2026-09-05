# ADR-0003: Topología de red de contenedores (host-mode selectivo)

* **Estado:** proposed
* **Fecha:** 2026-09-01
* **Decisores:** Jeremi
* **Fase AI-DLC:** 02-design
* **Versión:** 1.0.0
* **ID:** ADR-0003
* **Supersede / Superseded-by:** —
* **Controles OWASP afectados:** A01, A05

## Contexto
RF01 exige que cada sonda salga por una WAN concreta (`source_ip_address` de wan1/wan2). Detrás del bridge de Docker, el NAT reescribe el source y rompe la medición por interfaz. Además existe el conflicto conocido Docker ↔ nftables del proyecto de routing: Docker manipula cadenas propias y puede publicar puertos saltándose las reglas del firewall.

## Decisión
Topología mixta:
- `network_mode: host` **solo** para blackbox_exporter y la sonda de throughput (necesitan las interfaces reales; blackbox con `cap_add: NET_RAW` y contenedor no-root).
- Prometheus, Alertmanager, Grafana y Node-RED en una red bridge interna de Compose; **solo Grafana publica puerto a la LAN** (:3000). Prometheus (9090) y Alertmanager (9093) sin `ports:` — alcanzables únicamente dentro de la red de Compose.
- Regla operativa para el proyecto de routing: los servicios que requieran interfaces reales van a host-mode (patrón que también aplicará a MQTT/Node-RED si se decide así); lo demás vive en bridge interno y se gobierna el ingreso con la publicación explícita de puertos.

## Alternativas consideradas
| Opción | Pros | Contras | Riesgo de seguridad |
|---|---|---|---|
| Host-mode selectivo (elegida) | Medición correcta por WAN; superficie mínima publicada | Dos regímenes de red que documentar | Bajo: solo 9115 local en host |
| Todo en host-mode | Simple, sin NAT ni conflicto nftables | Todos los puertos quedan en el host → hay que filtrar cada uno en nftables | Mayor superficie |
| Todo en bridge + macvlan para sondas | Aislamiento elegante | Complejidad macvlan por WAN dinámica (DHCP de ISPs) | Media |

## Consecuencias
- Positivas: resuelve T2 (Prometheus no alcanzable desde LAN) por construcción; la sonda mide de verdad por interfaz.
- Negativas / deuda asumida: puertos host-mode (9115) deben cubrirse en la política INPUT de nftables del proyecto de routing.
- Impacto en threat model: reduce superficie de T2/T4; añade dependencia de la política INPUT del firewall.
