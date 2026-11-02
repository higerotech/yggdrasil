# ADR-0012: Ubicación de los servicios entre midgard y nidavellir

* **Estado:** proposed
* **Fecha:** 2026-10-31 (revisado el 2026-11-02: la fase 2 se adelanta, ver [Revisión](#revisión-del-2026-11-02-la-fase-2-se-adelanta-por-la-caída-del-ssd))
* **Decisores:** Jeremi
* **Fase AI-DLC:** 02-design
* **Versión:** 0.2.0
* **ID:** ADR-0012
* **Supersede / Superseded-by:** — (complementa ADR-0002: el placement sigue siendo local; este ADR reparte entre los dos hosts)
* **Controles OWASP afectados:** A04 (no concentrar en un solo host el router y las aplicaciones mientras no esté probado), A05 (el piloto no abre puertos nuevos en la LAN; la infraestructura compartida —NATS, RabbitMQ, OpenBao— no se expone fuera de midgard), A09 (el piloto se decide con métricas, no a ojo)

## Contexto

Hasta ahora todo vive en midgard salvo Bragi y el IdP de hive (`hive-idp`), que pasaron a nidavellir el
2026-10-26. El 2026-10-31, tras dos días de caídas de las WAN, Jeremi pidió evaluar si nidavellir puede
llevarse el resto, **router incluido**. Diagnóstico de los dos hosts ese día:

| | midgard (`hgtech001`) | nidavellir (`hgtech002`) |
|---|---|---|
| CPU | Intel i3-3240, 2 núcleos / 4 hilos (2012) | AMD Ryzen 3 2200G, 4 núcleos (2018) |
| RAM | 8 GB; memoria **comprometida al 93 %** (`sar -r`, 30-oct) | 16 GB (13,4 utilizables, el resto es de la iGPU); 2 GB en uso |
| Carga | 41 contenedores, CPU media 11 % | 8 contenedores, carga 0,1, PSI a cero |
| Red | `lan` en placa (RTL8111); `wan1` y `wan2` en adaptadores USB RTL8153 | **una sola NIC** (RTL8111) |
| Discos | Seagate de sistema con 16 sectores pendientes; SSD S700 que se cae bajo escritura sostenida | SSD de sistema ADATA (159 h, **un** error de lectura el 29-oct); Samsung HD154UI muriéndose (23 637 errores no corregibles, sin montar); WD de medios al 95 % |
| Estabilidad | Sin cuelgues; pila del CMOS agotada | **8 cuelgues** el 24 y 25-oct; ninguno desde `processor.max_cstate=1` y el watchdog (25-oct 14:40), 6 días |
| Energía | Sin UPS | Sin UPS |

### Las caídas de las WAN son de midgard, no de los proveedores

Los dos adaptadores USB de las WAN cuelgan de una **tarjeta PCIe USB 3.0 con chip VIA VL805**: el chipset
H61 de la placa solo tiene USB 2.0. Ninguno de los arranques desde el 28-oct registró errores del
driver `r8152`. Desde el reinicio del 30-oct a las 15:43 UTC:

- **30-oct 15:48:** `wan2` da `Tx timeout` y se reinicia por USB 3 veces. Queda con el enlace arriba y sin
  recibir un paquete durante 25,5 h. Se recupera bajando y subiendo la interfaz.
- **31-oct 17:32:** vuelve a fallar, ahora con `-71` (error de protocolo USB), 17 reinicios en 3 min.
- **31-oct 18:15:** se cambia de puerto el adaptador de `wan1`, que en el puerto 4-1 llevaba dos días sin un error.
  En el puerto 4-2 empieza a fallar igual: 63 reinicios hasta las 21:00, 19 en 15 min a las 21:20. La casa
  pierde internet 30–90 s con cada uno.

No hubo cambios de kernel, firmware ni paquetes entre los dos arranques. Que fallen dos adaptadores en
tres puertos de la misma tarjeta apunta a la tarjeta o a su alimentación auxiliar. Mudar el router con
esos adaptadores mudaría el problema.

### Qué ata cada servicio a un host

| Servicio | Dependencias | ¿Se puede mover solo? |
|---|---|---|
| Red de la casa: `dnsmasq`, nftables (`inet router`, `ip routernat`), `wan-balancer`, `wan-watchdog`, `pia-tunel` | Las tres interfaces físicas; la IP 192.168.10.1 está en la tablet, en las reservas DHCP y en la configuración de todos los equipos | Solo con 3 NIC en el destino |
| Heimdall: Huginn y Muninn, Sleipnir | Tienen que salir por cada WAN (ADR-0002) | Va con el router |
| Mimir, Odín, Gjallarhorn, Saga, Nornas | Observan a los dos hosts | Sí, pero no al host que se está evaluando |
| ves-market (9 contenedores: TimescaleDB, RabbitMQ, ingestores, API, SPA, túnel, respaldo) | Solo su red `ves-market`; su propio túnel de Cloudflare; 13 GB de datos; unidades de host de `ves-market-watch` (arranque, respaldo al NAS, vigía) | **Sí, en bloque** |
| transmission | El NAS (`/mnt/nas/descargas`, que nidavellir ya monta); el puerto 51413 abierto en el NAT de midgard | Sí |
| canario | Nada: es la app de prueba del receptor de despliegue | Sí |
| hive (gateway, engine, portal: 11 contenedores) | Redes externas `bifrost` (NATS), `hermod` (RabbitMQ), `andvari` (OpenBao) y `yggdrasil_saga` | No: arrastra la infraestructura compartida o la expone en la LAN |
| morocota (API, worker, DB, Redis, túnel) | `andvari` (OpenBao) | No, por el mismo motivo |

Además, nidavellir está en `PIA_MACS` (ADR-0009): todo lo que corre allí sale a internet por el túnel de
midgard a Bogotá, y cae a salida directa cuando el túnel no responde. El 31-oct se comprobó desde
nidavellir que Binance y el BCV, las fuentes de ves-market, responden por PIA (200 en 0,57 s y 0,64 s).

## Decisión

### 1. Reparto por roles

```mermaid
C4Deployment
    title Reparto objetivo entre midgard y nidavellir
    Deployment_Node(midgard, "midgard", "Ubuntu 24.04, i3-3240, 8 GB") {
        Deployment_Node(red, "Router de la casa", "systemd + nftables") {
            Container(dns, "dnsmasq", "DHCP y DNS", "Reservas y casa.lan")
            Container(balancer, "wan-balancer", "bash", "Multipath Servitel 5 : NetUno 2")
            Container(pia, "pia-tunel", "WireGuard", "Desvío por MAC")
        }
        Deployment_Node(obs, "Yggdrasil", "Docker Compose") {
            Container(heimdall, "Huginn, Muninn y Sleipnir", "blackbox, Ookla", "Salen por cada WAN")
            Container(mimir, "Mimir, Odín, Gjallarhorn", "Prometheus, Grafana, Alertmanager", "Observan los dos hosts")
        }
        Deployment_Node(compartida, "Infra compartida", "Docker Compose") {
            Container(infra, "Andvari, Bifröst, Hermod", "OpenBao, NATS, RabbitMQ", "Solo en redes Docker locales")
            Container(hive, "hive y morocota", "Compose", "Fase 2: con su infra")
        }
    }
    Deployment_Node(nidavellir, "nidavellir", "Ubuntu 24.04, Ryzen 3 2200G, 16 GB") {
        Deployment_Node(apps, "Aplicaciones", "Docker Compose, receptor con reconciliador") {
            Container(bragi, "Bragi", "Jellyfin", "Desde el 26-oct")
            Container(idp, "hive-idp", "Zitadel", "Desde el 26-oct")
            Container(ves, "ves-market", "TimescaleDB, RabbitMQ, ingestores", "Piloto, ola 2")
            Container(torrent, "transmission y canario", "Compose", "Piloto, ola 1")
        }
    }
    Rel(apps, red, "Sale a internet por", "LAN, PIA")
    Rel(mimir, apps, "Lee Thor :9471", "HTTP LAN")
```

*Eje estructura · fase 02-design. Lo que está en nidavellir o va en el piloto, y lo que se queda en midgard.*

- **midgard es el router y el observador.** Se queda con la red de la casa, Heimdall (que tiene que salir
  por cada WAN, ADR-0002) y el stack de Yggdrasil que vigila a los dos hosts. Un observador no puede
  vivir en el host que está evaluando.
- **nidavellir es el host de aplicaciones.** Ya tiene Bragi y hive-idp. Con el piloto suma ves-market,
  transmission y canario.
- **hive y morocota se quedan en midgard por ahora.** Moverlos exige llevar con ellos Andvari, Bifröst y
  Hermod, o publicar NATS, RabbitMQ y OpenBao en la LAN, que es un cambio de superficie de ataque. Se
  decide en una revisión de este ADR, con los datos del piloto. *Revisado el 2026-11-02: se mudaron antes
  del piloto, con su infraestructura, tras caerse el SSD de midgard. Ver la revisión al final.*

### 2. El router no se muda todavía

Volver a plantearlo exige estas tres condiciones a la vez:
1. nidavellir lleva **4 semanas seguidas sin cuelgues** con la carga del piloto, apagones aparte.
2. Ha pasado un test de memoria completo (memtest86+), con los dos módulos de marcas distintas.
3. Tiene una **tarjeta de red PCIe de al menos 2 puertos** para las WAN. No sirven adaptadores USB.

Aun cumpliéndolas, mover el router pone en un solo equipo la salida a internet y las aplicaciones. Si
ese equipo se cuelga, se pierden las dos cosas a la vez, y desaparece el segundo host desde el que
diagnosticar.

### 3. Un piloto de una semana antes de mover nada más

Mide si nidavellir aguanta carga real sin cuelgues ni degradación. Tiene dos olas, criterios de corte y
vuelta atrás: [piloto de nidavellir](../../05-deployment/piloto-nidavellir.md).

### 4. Requisito aparte: las WAN de midgard sin USB

Mientras las WAN dependan de la tarjeta VL805, midgard no es un router fiable, esté donde esté el resto.
Hay dos acciones, por orden:
1. Revisar el conector de alimentación auxiliar de la tarjeta.
2. Sustituir la tarjeta por una **NIC PCIe Intel de 2 puertos** (i226 o i350) en el mismo slot, y
   retirar los adaptadores USB. Precio y modelo: `<TODO: cotizar>`.

Esto no depende del piloto y lo arregla aunque el router acabe en nidavellir: la tarjeta se movería con él.

## Alternativas consideradas

| Opción | Pros | Contras | Riesgo de seguridad |
|---|---|---|---|
| **Roles separados + piloto (elegida)** | Libera la memoria de midgard; cada host conserva un fallo independiente; decisión con datos | Dos hosts que mantener; hive y morocota esperan | Ninguno nuevo: sin puertos nuevos en la LAN |
| Mover todo, router incluido, ya | Un solo host potente; se jubila midgard | nidavellir tiene 1 NIC y 6 días de estabilidad tras 8 cuelgues; un cuelgue deja la casa sin internet y sin servicios | Punto único de fallo para la red y los datos |
| Mover todo menos el router, de golpe | Libera midgard del todo | hive y morocota obligan a exponer NATS, RabbitMQ y OpenBao en la LAN; sin datos de cómo rinde nidavellir | Infra compartida accesible desde cualquier equipo de la LAN, incluido el wifi |
| Router en un solo puerto con VLAN | Bastaría la NIC de nidavellir | Exige un switch gestionable; 1 Gb/s compartido entre Servitel (1000) y la LAN | Mezcla en un cable el tráfico de fuera y el de dentro |
| Quedarse como está | Cero trabajo | midgard al 93 % de memoria comprometida y con las WAN cayéndose | — |

No hay matriz PxD: los dos candidatos son hardware propio con costo recurrente cero, y el único gasto es
la tarjeta de red (proporcionalidad, como en ADR-0002).

## Consecuencias

- **Positivas:** midgard recupera unos 1,6 GB de memoria con ves-market, sobre todo por TimescaleDB. Una
  caída de nidavellir ya no afecta a la red de la casa, y una de midgard deja vivas las aplicaciones ya
  movidas, aunque sin salida a internet.
- **Negativas / deuda:** las aplicaciones de nidavellir dependen de midgard para salir a internet y para
  PIA. Dos hosts sin UPS. El respaldo de ves-market y sus unidades de host (repo `ves-market-watch`)
  cambian de host.
- **Impacto en el threat model:** ninguno en el piloto. La fase 2 (hive y morocota) sí lo tiene, si expone
  la infraestructura compartida. Se evalúa en esa revisión.
- **Condiciones de revisión:**
  - termina el piloto, con su veredicto;
  - nidavellir se cuelga;
  - llega la tarjeta de red de midgard;
  - se cumplen las tres condiciones del punto 2.

## Revisión del 2026-11-02: la fase 2 se adelanta por la caída del SSD

**Qué pasó.** El 2026-11-01 a las 20:32 UTC el SSD de datos de midgard (`sdb`, HP S700) dejó de responder en
su puerto SATA. El kernel lo desactivó tras fallar el reinicio del enlace, y el sistema de ficheros abortó
su diario. En él estaban los almacenes de Bifröst (`/var/lib/bifrost`) y de morocota (`/var/lib/morocota`),
y las trazas de Saga (`/srv/rapido/saga`): hive y morocota quedaron sin servicio. Esta vez el SSD estaba casi
parado (3 kB/s de escritura), así que apunta a la conexión física o a la alimentación, no al desgaste.
Ese mismo día fallaba también la tarjeta USB de las WAN, que tira de la misma fuente.

**Decisión de Jeremi.**
- Mudar a nidavellir hive y morocota completos, con la infraestructura compartida (Andvari, Bifröst y
  Hermod). Es la opción «mover todo menos el router», pero sin su contra principal: la infraestructura viaja
  con sus clientes, así que **no se publica nada nuevo en la LAN**. Las redes de Docker se recrean en
  nidavellir con las mismas subredes y todo sigue publicado solo en `127.0.0.1`.
- Restaurar los datos del SSD desde los respaldos de esa madrugada, sin esperar a recuperar el disco.
- Mantener la salida de nidavellir por PIA.

**Cómo se hizo**, en la noche del 1 al 2 de noviembre, con cuatro scripts ejecutados desde el PC. Las claves
viajaron por tubería ssh entre los dos hosts, sin escribirse ni mostrarse por el camino.
1. Se copiaron a nidavellir las imágenes privadas exactas en uso (`docker save | docker load`), se
   descargaron las públicas por digest y se crearon las redes compartidas.
2. **Corte** (00:24–00:29 UTC):
   - En midgard, morocota salió del inventario del receptor, se desactivaron 9 temporizadores y 4 unidades
     de arranque, y se pararon 19 contenedores.
   - Se copiaron configuración, claves, unidades, scripts y los datos vivos de Andvari y Hermod, con sha256
     comparado en los dos hosts.
   - Bifröst se restauró del respaldo de las 02:48 UTC y morocota del volcado de las 03:15 UTC, sobre una
     base nueva migrada a la misma versión (0019).
3. Thor y Baldr movieron su vigilancia de midgard a nidavellir. morocota entró en el inventario del receptor
   de nidavellir, con las credenciales de GHCR. Los cuatro respaldos se probaron a mano.
4. El almacén de Bifröst pasó a `/srv/datos/bifrost`, montado en `/var/lib/bifrost`, porque su respaldo
   exige un punto de montaje.

**Resultado.** Los 21 contenedores sanos en nidavellir, sin errores en los registros. Los túneles de
Cloudflare tienen 4 conexiones cada uno, NATS recuperó sus streams y consumidores, y los respaldos al NAS
funcionan. `BifrostCaido` mira ahora la salud del contenedor que publica el Thor de nidavellir, no una sonda
al loopback de midgard.

**Desviaciones respecto a la decisión original.**
- La fase 2 va antes del piloto. nidavellir no ha pasado la prueba de estrés, que sigue pendiente y ahora
  importa más: lleva hive y morocota.
- **Datos perdidos:** lo escrito en Bifröst y morocota entre los respaldos (02:48 y 03:15 UTC) y la caída
  del SSD (20:32). La copia de midgard queda en el SSD, por si vuelve.
- **PIA:** morocota (PagoASAP, Auth0, Twilio, Meta, Resend, S3) y hive (LLM, Gmail, Facebook) salen por una
  IP de VPN. Si un proveedor la bloquea, hay que sacar nidavellir de `PIA_MACS`.

**Pendiente.**
- **Saga (Tempo):** sigue en midgard con su almacén en el SSD caído, y la red `yggdrasil_saga` de nidavellir
  está vacía. Hive no envía trazas hasta que Tempo tenga almacén y sea alcanzable desde nidavellir.
- Revisar en midgard el cable y la alimentación del SSD y de la tarjeta USB.
- Las configuraciones originales siguen en midgard, con sus unidades desactivadas. Retirarlas cuando
  nidavellir lleve unas semanas estable.
