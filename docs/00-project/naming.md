# Convención de nombres — Yggdrasil

* **Estado:** approved
* **Fecha:** 2026-09-01
* **Decisores:** Jeremi
* **Fase AI-DLC:** 00-project
* **Versión:** 0.4.0
* **Tema:** Mitología nórdica (sucesor espiritual de Centinela)

## Regla
Cada servicio recibe un nombre del universo nórdico cuya función mitológica refleje su función técnica. El nombre técnico real siempre va en el slot de tecnología del C4 y en los `container_name` de Compose, para que el diagrama sea legible por terceros.

## Topología de mundos
| Mundo | Rol en la plataforma |
|---|---|
| **Yggdrasil** | La plataforma completa (el árbol que conecta todos los mundos) |
| **Midgard** | Tier edge: el appliance en la pared (captura y datos crudos) |
| **Nidavellir** | El taller: segundo servidor de la LAN (`hgtech002`, 192.168.10.2, alias DNS `nidavellir.casa.lan`). El reino de los enanos herreros que forjaron Mjölnir y Gungnir → compilación, contenedores y cómputo con GPU (2026-10-25) |
| **Asgard** | Tier nube (futuro): dashboards y notificaciones escalables |
| **Bifrost** | El puente edge ↔ nube (hoy WireGuard). Ojo: «Bifröst» nombra también el bus de eventos de `/srv/infra/bifrost` (abajo) |

## Servicios actuales (F-001 Heimdall)
| Nombre | Tecnología | Función mitológica → técnica |
|---|---|---|
| **Heimdall** | Servicio Monitor SLA (conjunto) | El guardián del Bifrost que ve a cien leguas → vigila los dos enlaces WAN |
| **Huginn** y **Muninn** | Módulos blackbox_exporter (wan1/wan2) | Los cuervos de Odín que salen cada día y vuelven con noticias → sondas ICMP y TCP+TLS por WAN |
| **Sleipnir** | Sonda de throughput (CLI de Ookla; `speedtest` e `iperf3` como alternativas) | El caballo de ocho patas, el más veloz → mide la velocidad real |
| **Mimir** | Prometheus (TSDB + reglas) | El pozo de la sabiduría y la memoria → guarda y evalúa las métricas |
| **Gjallarhorn** | Alertmanager | El cuerno de Heimdall que suena cuando algo amenaza → alertas |
| **Odín** | Grafana | Desde su trono ve todos los mundos → dashboards |
| **Nornas** | Node-RED | Tejen el destino a partir de los hilos → automatización sobre eventos |
| **Ratatosk** | Mosquitto (MQTT) | La ardilla mensajera que recorre Yggdrasil → bus de eventos |
| **Thor** | Métricas del host (recolector + httpd de busybox) | La fuerza de la máquina → salud del disco, espacio del NAS, qué WAN lleva el balanceador en la ruta (2026-10-16), estado de los servicios y último respaldo |
| **Hlidskjalf** | Tablero de pared (página servida por Nornas + app Android kiosco en una tablet) | Hliðskjálf, el trono desde el que Odín ve todos los mundos → el estado de midgard de un vistazo (ADR-0007, 2026-10-16) |
| **Fáfnir** | Catálogo del almacenamiento (script de Python + SQLite, en midgard y nidavellir) | El dragón que guarda el tesoro y sabe cada pieza que hay en él → inventaría el NAS y los discos, cuenta las copias de cada colección y avisa de lo que solo vive en un disco que falla (ADR-0010, 2026-10-25) |
| **Baldr** | Protocolo tras el arranque (script + unidad de systemd, en midgard y nidavellir) | El dios que vuelve del reino de los muertos → tras un apagón espera al NAS, reintenta lo que no volvió, relanza los jobs perdidos y da el parte (ADR-0011, 2026-10-28) |
| **Saga** | Grafana Tempo (trazas) | La diosa de la historia, que cada día bebe con Odín en Sökkvabekkr → guarda la historia de cada mensaje y se consulta desde Odín (ADR-0008, 2026-10-19) |

## Otros servicios de midgard (fuera de Yggdrasil)
Proyectos hermanos que corren en el mismo appliance; Yggdrasil vigila su arranque y su respaldo
(Thor, `THOR_UNIDADES` y `THOR_RESPALDOS`), pero no los despliega.

| Nombre | Qué es | Dónde |
|---|---|---|
| **Bifröst** | Bus de eventos de la infraestructura de midgard | `/srv/infra/bifrost`, `bifrost-arranque.service` y `bifrost-respaldo.timer` |
| **Hermod** | Broker de mensajería (el mensajero de los dioses) | `/srv/infra/hermod`, `hermod-arranque.service` y `hermod-respaldo.timer` |
| **Andvari** | Gestor de secretos del appliance, OpenBao (el enano que guarda el tesoro) | repo `higerotech/andvari`, `/srv/infra/andvari` |
| **Bragi** | Servidor de medios Jellyfin | repo `higerotech/bragi`; Yggdrasil integra su salud (8 alertas) |

## Espacio de tópicos MQTT
Prefijo por mundo: `midgard/...` para lo generado en el edge (p. ej. `midgard/wan/wan1/estado`), reservado `asgard/...` para el tier nube.

## Nombres reservados (futuros servicios)
| Nombre | Candidato para |
|---|---|
| **Fenrir** | Frigate NVR (el lobo vigilante); proyecto independiente `higerotech/fenrir`. Se integró en la 0.5.1 y salió de midgard en la 0.5.3 (ADR-0004); el nombre queda reservado |
| **Loki** | Agregación de logs (coincide con Grafana Loki) |
| **Freyja** | Sensores IoT / Home Assistant si llegara |
| **Valhalla** | Archivo frío / respaldos de largo plazo (los respaldos diarios actuales van al NAS y se nombran por proyecto) |

Nota feliz: el ecosistema Grafana ya usa nombres nórdicos (Loki, Mimir), así que futuras adopciones encajan en el tema sin fricción.

## Revisiones

> **Revisión 2026-10-19.**
> - Se registran los servicios hermanos que Thor vigila: Bifröst, Hermod, Andvari y Bragi. Bragi
>   pasa de reservado a integrado (0.5.6).
> - **Pendiente de decidir (HITL):** «Bifröst» nombra a la vez el mundo puente edge ↔ nube y el bus
>   de eventos de `/srv/infra/bifrost`. Hay que elegir si se renombra uno de los dos.

> **Revisión 2026-10-25.**
> - Nuevo mundo **Nidavellir** para `hgtech002`, el segundo servidor de la LAN (decisión de Jeremi). El
>   hostname no cambia, como `hgtech001` en Midgard: el nombre nórdico es el alias del mundo en la
>   documentación y en el DNS de la casa (`cname` en dnsmasq de midgard, `nidavellir.casa.lan`).

> **Revisión 2026-10-25 (0.4.0).** Nuevo servicio **Fáfnir**, el catálogo del almacenamiento (decisión de Jeremi;
> alternativas descartadas: Brokkr y Mímisbrunnr, este último por parecerse a Mimir).
