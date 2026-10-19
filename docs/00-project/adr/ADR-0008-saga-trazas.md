# ADR-0008: Saga, el almacén de trazas de la plataforma, con Grafana Tempo en el SSD

* **Estado:** accepted
* **Fecha:** 2026-10-19
* **Decisores:** Jeremi
* **Fase AI-DLC:** 02-design
* **Versión:** 1.0.0
* **ID:** ADR-0008
* **Supersede / Superseded-by:** —
* **Controles OWASP afectados:** A01 (los emisores solo alcanzan Saga, no Mimir ni Odín), A05 (sin puertos publicados), A09 (las trazas no llevan datos personales: lo fija cada emisor)

## Contexto

El gateway de mensajería (`jeremialcala/wh-python-fastapi-messenger`) emite trazas OpenTelemetry desde su I5. Cada
mensaje se sigue en una traza, del webhook al motor de respuestas, con su contexto W3C en cada evento del bus. Yggdrasil
tenía métricas (Mimir) y alertas (Gjallarhorn), pero no un sitio donde guardar trazas y consultarlas. Sin él, el
gateway las genera y nunca salen del proceso.

midgard es un Core i3-3240 con 7,6 GB de RAM (unos 4 GB libres) y desde el 2026-10-19 tiene un SSD de 1 TB montado
en `/srv/rapido`, vigilado por Thor. El HDD del sistema está degradándose: 16 sectores pendientes.

## Decisión

- **Saga es Grafana Tempo 3.1.0** en modo monolítico (`-target=all`), que no necesita Kafka. El nombre lo eligió
  Jeremi: Saga es la diosa de la historia, y cada día bebe con Odín. Tempo se consulta desde Grafana.
- **15 días de retención** (`overrides.defaults.compaction.block_retention: 360h`), decisión de Jeremi del
  2026-10-19.
- **Almacén local en el SSD:** `/srv/rapido/saga`, con dueño 10001, el usuario de la imagen. Tempo no está probado
  en discos mecánicos.
  - El compose lo monta sin `create_host_path`, y `bootstrap-midgard.sh` solo lo crea con el SSD montado.
  - Sin el SSD, Saga no arranca, en vez de escribir en el HDD.
- **Solo OTLP por HTTP (4318)** para recibir y el 3200 para consultar. Ningún puerto publicado.
- **Una red propia para los emisores, `yggdrasil_saga`.** Saga está en ella y en `heimdall`, por donde la consultan
  Odín y la lee Mimir.
  - Un emisor que entra en `yggdrasil_saga` no alcanza a Mimir, que tiene la API de administración activada
    (`--web.enable-lifecycle`), ni a Odín.
  - El webhook del gateway está expuesto a internet: por eso no se le une a `heimdall`, como sí se hace con Bragi.
- **Sin `metrics_generator`:** las métricas derivadas de las trazas necesitarían escritura remota en Mimir, que no la
  tiene activada. El grafo de servicios de Grafana queda sin configurar; el de cada traza sí se dibuja.
- **Endurecida como el resto:** `read_only`, sin capacidades (`cap_drop: ALL`), `no-new-privileges`, `mem_limit:
  512m` y `memory.automemlimit_enabled`, para que Go no pase de su límite.
- **Vigilada por Mimir:** job `saga` y alerta `SagaCaida` (warning, 5 min). La imagen es distroless, sin shell ni
  `wget`, así que no hay healthcheck en el contenedor.

Qué llevan las trazas lo decide cada emisor. El gateway aplica la regla de sus logs: solo identificadores que él
mismo dio, rutas y recuentos, nunca números ni texto (RS19 del gateway).

## Alternativas consideradas

| Opción | Pros | Contras |
|---|---|---|
| **Grafana Tempo en Yggdrasil** | Se consulta desde Odín, que ya está; un solo servicio; almacén local suficiente para una casa | Tempo está pensado para almacenamiento de objetos; sin metrics_generator no hay grafo de servicios |
| Jaeger (all-in-one) | Trae su propia interfaz | Otra interfaz más que mantener y asegurar; la consulta no se integra con Mimir ni con Odín |
| SigNoz u otra plataforma completa | Métricas, logs y trazas juntas | Varios servicios y una base ClickHouse: demasiado para midgard |
| No guardar trazas | Nada que operar | RNF09 del gateway queda sin ver: el contexto viaja, pero nadie lo consulta |

Es un único candidato viable a coste cero, autoalojado en midgard. Por proporcionalidad, la ADR va sin matriz PxD.

## Consecuencias

- **El presupuesto de RAM del stack** (suma de `mem_limit`) pasa de 1680 a 2192 MB. En reposo, Saga usa 21 MiB,
  medido en local.
- **Espacio en el SSD:** lo que se ingiera al día por 15 días. Con el gateway de una casa son unos pocos MB al día.
  Thor vigila el montaje de `/srv/rapido`.
- **Para emitir trazas, un servicio entra en la red externa `yggdrasil_saga`** y apunta su
  `OTEL_EXPORTER_OTLP_ENDPOINT` a `http://saga:4318`.
- **Desde esa red, un emisor podría consultar trazas en el 3200.** Tempo no separa el receptor de la consulta por
  red. Se acepta: los únicos emisores son servicios propios, y las trazas no llevan datos personales.

## Condiciones de revisión

- Las trazas ocupan más de lo que el SSD puede dar en 15 días.
- Hace falta el grafo de servicios: entonces, `metrics_generator` con escritura remota en Mimir.
- Entra un emisor que no sea propio.
