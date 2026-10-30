# Changelog

Todos los cambios notables de este proyecto se documentan en este archivo.

El formato está basado en [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/),
y este proyecto se adhiere a [Versionado Semántico](https://semver.org/lang/es/).

## [Unreleased]

> Gate 4 (Deployment) abierto el 2026-10-19 sobre el sistema que opera en midgard desde la 0.4.0.

### Cambiado
- **Los proveedores tienen nombre y el SLO de throughput es su garantía** (`wan:slo_throughput_mbps`).
  `wan1` es Servitel (1000/1000 Mbps) y `wan2` es NetUno (400/400 Mbps), que sustituyó a Silverdata
  (1000/500) hacia el 2026-10-19. Los dos garantizan el 90 % del plan: los umbrales pasan de 800/800 y
  800/400 a **900/900 y 360/360**. Con el umbral viejo, `WanThroughputBajo` llevaba días disparada para wan2
  a 420 Mbps de bajada, por encima de lo contratado. Sobre los 30 días previos, los umbrales nuevos solo
  habrían alertado del 21 al 24-oct, cuando NetUno entregó 180–370 Mbps. Prueba nueva
  `tests/throughput.test.yml` (falla con las reglas de develop). El panel de throughput de Odín dibuja
  el SLO de cada WAN en vez de un umbral fijo de 800. Glosario, charter, PRD, arquitectura y despliegue
  nombran a los proveedores.
- **El balanceador da más peso a Servitel** (`deploy/host/wan-balancer.sh`). La ruta multipath pasa de 1:1 a
  **5:2**, en proporción a los planes: Servitel (wan1) vende 1000/1000 y NetUno (wan2) 400/400. Con 1:1, la
  mitad de las conexiones de la casa iban al enlace de 400, que además pierde paquetes a ráfagas desde el
  cambio de proveedor. El reparto sigue siendo por conexión (`fib_multipath_hash_policy=1`).

### Corregido
- **El MSS de los equipos desviados por PIA** (`deploy/host/pia-tunel.sh`, ADR-0009 1.1.2). La tabla
  `inet yggdrasil_pia` gana la cadena `mss`, que recorta el SYN de lo que sale por `pia0` a la MTU del túnel
  (`rt mtu`: 1380, MSS 1340). Sin ella anunciaban 1460. El 2026-10-28 el SMTP de Zitadel en Nidavellir, que
  sale por PIA, no llegaba a Resend: el saludo pasaba y el TLS se colgaba al llegar el certificado. Desde
  midgard, que no sale por el túnel, funcionaba. La ADR decía «MSS recortado» y solo lo estaba en las WAN.
  `prueba-pia.sh` pasa a 70 comprobaciones.

## [0.5.22] - 2026-10-28

**Lo que destapó el cuarto corte.** A las 18:28 del 2026-10-28 la luz se fue por cuarta vez. Al volver, el SSD de
midgard llegó tarde y `/var/lib/bifrost` no se montó: Hive pasó 77 min sin bus, Baldr dio el parte por bueno y la
alerta de la plataforma tardó 33 min.

### Añadido
- **Vigilancia de las piezas de Hive en la plataforma** (`rules/hive-alertas.yml`, con sus pruebas).
  - **`BifrostCaido`.** Blackbox, en host-mode, sondea `/healthz` de NATS en `127.0.0.1:8222` de midgard
    (job `bifrost`, módulo `http_nats_salud`). El 2026-10-28 `bifrost-nats` pasó 77 min en bucle de
    reinicios con su almacén sin montar, y `ServicioDePlataformaCaido` tardó 33 min en avisar: Thor lo veía
    sano en cada arranque y el `for` volvía a cero. La nueva avisa a los ~2 min, porque falla con la media de
    las sondas, no con una sola.
  - **`ZitadelExternoCaido`.** `https://hive-auth.higerotech.com/debug/healthz` debe responder `ok` desde
    fuera (job `zitadel_externo`, módulo `https_zitadel_salud`).
  - **El respaldo de Zitadel.** Mimir lee `hive_idp_respaldo.prom` de nidavellir (job `hive_idp_respaldo`).
    Avisan `ZitadelRespaldoAtrasado` (más de 26 h), `ZitadelRespaldoFallido` y `ZitadelRespaldoSinMetricas`.
  - **Nidavellir caído** ya lo cubría `ThorSinMetricas`. El README de `deploy/cd` añade los contenedores y
    timers de Zitadel a la configuración de Thor en nidavellir.

### Corregido
- **Baldr recupera un montaje que cayó por su dependencia y lo que corría sin él** (ADR-0011 1.1.0). En el
  corte del 2026-10-28 a las 18:28, el SSD de midgard no apareció antes de su `device-timeout` y
  `/var/lib/bifrost` quedó sin montar: `bifrost-nats` en bucle y Hive 77 min sin bus, con un parte de
  Baldr que decía que todo iba bien.
  - Reintenta también el montaje `inactive` sin trabajo en cola, no solo el `failed`. El que aún pasa su
    fsck se sigue esperando.
  - Tras recuperarlo, reinicia los contenedores que ya corrían con un bind por debajo de él.
  - Cuenta como pendiente un contenedor en bucle de reinicios o `unhealthy`.
  - El ejemplo de midgard añade `/srv/rapido`, `/var/lib/bifrost` y `/var/lib/morocota` a
    `BALDR_MONTAJES`.
  - `prueba-baldr.sh`: 72/72 (10 nuevas).

## [0.5.21] - 2026-10-28

**Baldr, el protocolo tras un apagón.** El 2026-10-28 hubo tres cortes de luz: de 7 h 47 min, 7 min y 11 min.
Tras el primero, el arranque dejó cosas mal sin que nada avisara. Baldr ya gestionó solo el segundo y el
tercero en los dos hosts, y dio el parte por push.

### Añadido
- **Baldr, el protocolo tras un apagón** (ADR-0011). Corre una vez tras cada arranque en midgard y en
  nidavellir. El apagón del 2026-10-28 (7 h 47 min) dejó unidades de arranque fallidas, un montaje del NAS
  caído con su contenedor, un respaldo lanzado antes que el NAS y un catálogo de Fáfnir sin inventarios,
  y casi nada avisó.
  - Espera a NTP, al NAS y a los montajes, y reintenta los que fallaron.
  - Reintenta las unidades `*-arranque` que no convergieron y arranca los contenedores que murieron
    durante el arranque.
  - Relanza solo los jobs declarados (`BALDR_JOBS`) que corrieron antes de tiempo o fallaron.
  - En midgard, a los 15 min, revisa las alertas y manda un push con el parte.
  - Thor publica su estado (`yggdrasil_baldr_*`); `BaldrConPendientes` y `BaldrSinTerminar` salen también
    en Hlidskjalf.
- Thor publica las unidades de systemd en `failed` y los contenedores que murieron durante el arranque.
  Avisan `UnidadFallida` y `ContenedorCaido`, sin duplicar lo que ya cubre `yggdrasil_servicio_ok`.

### Corregido
- **`yggdrasil-arranque` reintenta si el stack no converge** (`Restart=on-failure`, 5 veces en 20 min).
  Tras los apagones del 2026-10-24 y el 2026-10-28 falló porque Nornas aún no estaba sano, y nadie se
  enteró.
- La prueba de Thor ya no lee el estado real del túnel PIA ni el de Baldr cuando corre en midgard.
- `yggdrasil-baldr.sh verificar`, a mano, lee `/etc/default/yggdrasil-baldr`: sin él no verificaba nada.
  Sin una pasada previa en este arranque, calcula la ventana en vez de darla por un reinicio ordenado.
  En un host sin Mimir (`BALDR_VERIFICAR=0`) no consulta Gjallarhorn. Visto al instalarlo el 2026-10-28.
- **Baldr espera a cada montaje** (`BALDR_ESPERA_MONTAJE_S`, 5 min), no solo al NAS. En el apagón de
  las 15:22 del 2026-10-28, el WD de nidavellir pasó su fsck y montó 4 s después de que Baldr lo diera por
  perdido: un falso «sin montar» en el parte. La lectura del registro del arranque anterior tiene tope
  (`BALDR_ESPERA_REGISTRO_S`, 15 min): con el HDD de midgard saturado tardó 3,5 min. Si no termina, el
  arranque se trata como un corte sin hora de caída, en vez de dejar a Baldr colgado.
- `yggdrasil-baldr.sh verificar` se niega mientras la pasada automática sigue en marcha. Lanzado a mano a
  las 17:50 del 2026-10-28, dejó su estado en fase 5 mientras ella esperaba para verificar.
- **Hlidskjalf: ninguna fila asoma por detrás del pie de Host.** Cuando Host no cabía, el pie
  nombraba las filas tapadas, pero la primera empezaba por encima de él y se veía cortada (la
  fila «Medios» de nidavellir, 2026-10-26). Ahora esas filas se ocultan sin mover las demás, y
  solo las nombra el pie.

## [0.5.20] - 2026-10-26

### Cambiado
- **Mimir lee Bragi en nidavellir.** Bragi se muda allí (ADR-0010 de Bragi). El job `bragi` pasa de
  `bragi-metricas:9470`, en la red heimdall, a `192.168.10.2:9471` con `host="nidavellir"`. Ese
  `bragi.prom` lo sirve el httpd de Thor, que solo admite a midgard. Las alertas no cambian.

## [0.5.19] - 2026-10-26

**Fáfnir cataloga el almacenamiento de midgard y nidavellir** (ADR-0010): sabe qué hay en el NAS y en cada disco,
cuántas copias sanas tiene cada colección y qué solo vive en un disco que falla, y mueve verificando.

### Añadido
- **Fáfnir, catálogo del almacenamiento de midgard y nidavellir** (ADR-0010, `deploy/fafnir/`).
  - Inventaría cada día, en cada host, el NAS y los discos; publica el inventario en el NAS (`descargas/fafnir`), y
    midgard lo junta en un SQLite.
  - Cuenta las copias de cada colección por medio físico sano y por contenido (tamaño + huella: SHA-256 en los
    respaldos, huella rápida en los vídeos), y marca lo que solo vive en un disco que falla.
  - `fafnir.py informe` lo cuenta; `fafnir.py mover` copia verificando cada fichero y solo borra el origen con
    `--borrar-origen` y sin fallos.
  - Mimir recoge `fafnir.prom` (job `fafnir`) y avisa con `FafnirDatosEnRiesgo`, `FafnirColeccionSinCopias`,
    `FafnirInventarioViejo` y `FafnirSinCatalogo`.
  - `bootstrap-midgard.sh` lo instala en midgard (paso 5h); en nidavellir se instala a mano.
  - Pruebas: `deploy/fafnir/tests/test_fafnir.py` (18) y `fafnir-alertas.test.yml` (4 grupos).
  - Convención de nombres 0.4.0.

### Corregido
- **El inventario de Fáfnir ya no desplaza la caché de Bragi.** Leer cientos de GB llenaba la caché de páginas
  (12 GB de pico en nidavellir). `fafnir-escaneo.service` lleva `MemoryHigh=1G`: el inventario recicla su propia
  caché antes que la de los demás.

## [0.5.18] - 2026-10-25

### Corregido
- **Hlidskjalf no mostraba nidavellir mientras estaba en marcha.** El resumen pedía
  `{__name__=~"…"} or up{job="thor"}`, y `or` compara las etiquetas sin el nombre: el `up` de un host coincidía
  con su `yggdrasil_thor_timestamp_seconds` y se descartaba. Solo habría aparecido al colgarse. Ahora el `up` lleva
  la etiqueta `serie="up"` (`label_replace`). Comprobado contra el Mimir de midgard: 130 series, con los dos `up`.

## [0.5.17] - 2026-10-25

**Hlidskjalf y las alertas ven también nidavellir, y el PC desviado por PIA vuelve a resolver la casa:** Thor corre
en el segundo servidor de la LAN y avisa si se cuelga o se reinicia (ADR-0007 1.1.0); la revisión a 30 días de
la ADR-0009 queda programada.

### Añadido
- **Hlidskjalf y las alertas de Thor ven también nidavellir** (ADR-0007 1.1.0).
  - Thor corre en nidavellir con su propia configuración. Lo sirve en la LAN `yggdrasil-thor-http.service`, solo
    para midgard (`IPAddressAllow`), y Mimir lo recoge en el job `thor` con la etiqueta `host="nidavellir"`. Las
    series de midgard no cambian.
  - Métricas nuevas de Thor, en todos los hosts: `yggdrasil_arranque_timestamp_seconds` y
    `yggdrasil_cpu_temperatura_celsius`. `THOR_WANS` admite estar vacía, para un host sin balanceador.
  - Alertas nuevas: `HostReiniciado` (arranque en los últimos 15 min: apagón o cuelgue resuelto por el watchdog)
    y `ServicioDeHostCaido` (un servicio de otro host, que no tiene el vigía de midgard). Las alertas de discos,
    puntos y Thor nombran el host cuando no es midgard; las de las WAN y el espacio del NAS solo miran midgard.
  - El tablero pinta cada host como un bloque en el panel de midgard (antes «Host»): cabecera con su estado y la
    CPU, y debajo sus discos, volúmenes y servicios. Un host colgado sale «NO RESPONDE», y la cabecera de la
    página lo dice.
  - Pruebas: `prueba-thor.sh` pasa de 74 a 81 comprobaciones, `thor-alertas.test.yml` de 15 a 21 grupos y
    `hlidskjalf.test.mjs` de 23 a 27 `test()`. Los escenarios de la vista previa llevan a nidavellir.
- **Revisión a 30 días de la ADR-0009, programada.**
  - `pia-tunel.sh` cuenta las sondas por el túnel (solo con el desvío activo), las perdidas, el RTT, los
    levantamientos y los rechazos de PIA. Thor los publica como `yggdrasil_pia_sondas_total`,
    `yggdrasil_pia_sondas_perdidas_total`, `yggdrasil_pia_rtt_ms`, `yggdrasil_pia_levantamientos_total` y
    `yggdrasil_pia_rechazos_total`.
  - `deploy/cd/revisar-adr-0009.sh` aplica las condiciones de revisión de la ADR sobre 30 días de Mimir.
    - Compara con la WAN directa que menos pierde y con el mismo destino, `1.1.1.1`.
    - Propone mantener la Fase 1, pasar a la Fase 2, revertir, o esperar si faltan datos.
    - El informe llega por ntfy y se guarda en `/var/lib/yggdrasil-revisiones/`.
  - `yggdrasil-revision-adr-0009.timer` lo ejecuta el 2026-11-20 a las 09:00 (Caracas) y lo instala
    `bootstrap-midgard.sh`.
  - Seguimiento en la issue #88, del milestone «Revisión ADR-0009 (2026-11-20)».
  - Prueba nueva: `deploy/cd/tests/prueba-revision.sh`, con 21 comprobaciones.

### Corregido
- **`hlidskjalf/vista-previa.sh` restaura la URL de producción.** En la tablet, `run-as <paquete> test -f` sale con 1
  aunque el fichero exista: `probar` no medía y `cerrar` habría dejado la tablet en la vista previa. La comprobación
  va dentro de `sh -c`.
- **El PC desviado por PIA vuelve a resolver los nombres de la casa.** El DNAT del túnel llevaba todo su DNS al
  de PIA, también `casa.lan`, que PIA no conoce. Ahora `pia-tunel.sh` arranca un reenviador (un dnsmasq aparte
  en `192.168.10.1:5354`): los nombres de la casa y la inversa de la LAN van al dnsmasq de midgard, y el resto
  va al DNS de PIA por el túnel, así que el ISP sigue sin ver las consultas. Si el reenviador no arranca, el
  DNS vuelve directo al de PIA. `/etc/nftables.conf` abre el puerto 5354 solo a lo que llega por ese DNAT
  (`ct status dnat`), y `pia-tunel.service` suma `CAP_SETUID` y `CAP_SETGID`, para que dnsmasq baje a su usuario, y `CAP_KILL`,
  para vigilarlo y pararlo.
  ADR-0009 1.1.1; `prueba-pia.sh` pasa de 55 a 69 comprobaciones.

### Cambiado
- **Threat model:** DREAD de T11 (3,2) y T12 (3,8) aceptado (HITL 2026-10-21).
- **Convención de nombres 0.3.0:** nuevo mundo **Nidavellir**, el taller, para `hgtech002`, el segundo servidor de
  la LAN (192.168.10.2, alias DNS `nidavellir.casa.lan`).

## [0.5.16] - 2026-10-21

**Una WAN que pierde paquetes sale de la ruta, y el PC de Jeremi sale por PIA:** wan-balancer mide la pérdida y ya
no deja en el multipath una WAN que responde por TCP pero pierde un 20 % (ADR-0009, túnel WireGuard desde midgard).

### Añadido
- **ADR-0009 (propuesta): túnel para las llamadas.** Fase 1: WireGuard a PIA desde midgard, solo para el tráfico
  de tiempo real (Chime, Teams, Meet y Zoom), con su salida por la mejor WAN y vuelta a la salida directa si el
  túnel cae. Fase 2, solo si los datos lo piden: un VPS propio en Miami con engarde, que duplica cada paquete por
  las dos WAN, con PIA de respaldo y segunda región. Matriz PxD con cinco candidatos.
  - La medición del 2026-10-21 a seis regiones de PIA muestra que cada WAN tiene una región cercana distinta:
    wan1 está a 21 ms de Bogotá y wan2 a 33 ms de Miami.
  - La llamada de ese día ya iba por PIA desde el PC, como un único flujo UDP que el multipath puso en wan2.
  - Herramienta de solo lectura `deploy/host/medir-tuneles.sh`, en el ShellCheck del CI.
- **ADR-0009 aceptada (HITL 2026-10-21) y túnel PIA en midgard (`pia-tunel`).** Jeremi cambia el alcance de la
  Fase 1: todo el tráfico de su PC, elegido por MAC, sale por PIA, no solo las llamadas. Acepta T12 y deja de usar
  la app de PIA en el PC.
  - `deploy/host/pia-tunel.sh` y `pia-tunel.service` hacen el trabajo:
    - WireGuard `pia0` con MTU 1380.
    - Tabla propia `inet yggdrasil_pia`: marca por MAC, DNS al de PIA, IPv6 hacia fuera descartado y masquerade.
    - Reglas 87/88: la LAN y Docker siguen en local.
    - Sonda cada 5 s por el túnel: con 3 fallos los equipos salen directo y el túnel se rehace con otra clave.
  - Las credenciales viven en `/etc/yggdrasil-pia.env` (root 600) y las escribe Jeremi. Usuario, contraseña,
    token y clave privada llegan por descriptor, nunca como argumento ni al journal.
  - Prueba nueva `deploy/host/tests/prueba-pia.sh`, 48 comprobaciones más `nft -c` de la tabla real en el CI.
  - `install-host.sh` instala el túnel y el certificado de PIA, y solo arranca el servicio si existen las
    credenciales.
- **Thor publica el estado del túnel** (`yggdrasil_pia_*`) y vigila `pia-tunel.service`. Alertas nuevas
  `TunelPiaSinDesvio` y `TunelPiaCaido`, con dos grupos nuevos en `thor-alertas.test.yml`.
- **Threat model:** T11 (credenciales de PIA en midgard) y T12 (PIA ve los metadatos del PC, riesgo aceptado),
  con puntuaciones propuestas. `data-classification.md` añade las credenciales, el token, la clave y los
  metadatos.

### Cambiado
- **`wan-balancer` saca una WAN que pierde paquetes, aunque responda por TCP.** Del 19 al 21 de octubre wan2
  perdía un 15-30 % de los ping y solo fallaba el 2 % de las comprobaciones HTTPS. Nunca sumaba 3 fallos
  seguidos, así que se quedó en el multipath con la mitad de los flujos de la casa, una llamada de Slack entre
  ellos.
  - **Ventana de pérdida:** en cada chequeo, un ping a cada objetivo ICMP de Heimdall. La WAN sale si pierde
    ≥ 3 de 48 en 2 min, contando los dos mejores objetivos, y vuelve con ≤ 1 y la ventana llena.
  - **Menos tolerancia:** sale con 2 fallos TCP seguidos (eran 3) y vuelve con 6 aciertos (eran 3).
  - **Las dos fuera:** la ruta va por la menos mala, en vez de conservar la última. Cuatro veces un corte de
    segundos en wan1 había mandado la casa entera por wan2.
  - Umbrales calibrados con 7 días de sondas de Heimdall. Prueba nueva `deploy/host/tests/prueba-perdida.sh`
    en el CI; detalle en `deploy/host/README.md`.
- **`WanSanaFueraDeRuta`** no avisa de una WAN que el balanceador saca por pérdida: exige 15 min sin pérdida
  ≥ 1 % antes de contar los 10 min (grupo nuevo en `thor-alertas.test.yml`).

### Corregido
- `inventario-pruebas.md`: las referencias de línea a `validar-configs.yml` estaban desfasadas desde la 0.5.14.

## [0.5.15] - 2026-10-19

**Andvari vigilado:** un Andvari sellado, o cualquier contenedor de `/srv/infra` caído (Andvari, Bifröst, Hermod),
avisa ahora por Mimir. Hliðskjálf muestra los tres.

### Añadido
- **Vigilancia de Andvari y del resto de `/srv/infra`.** Hasta ahora, un Andvari sellado no avisaba a nadie.
  - **Thor** vigila los contenedores de `THOR_CONTENEDORES` (`andvari-openbao`, `bifrost-nats` y `hermod-rabbitmq`),
    aunque no sean del proyecto, y publica si Andvari está sellado (`yggdrasil_andvari_sellado`, con `bao status`).
  - **Mimir** avisa con `AndvariSellado` (crítica, 2 min): sin Andvari, el gateway responde 503 a todo lo cifrado.
    Avisa también con `ServicioDePlataformaCaido` (crítica, 5 min), que no se repite con un Andvari sellado.
  - **Hliðskjálf** muestra los tres. Con esto, `bifrost-nats` sale por fin en el tablero.
  - **Pruebas:** en `prueba-thor.sh`, un contenedor de fuera que no existe, el sello abierto, el sello cerrado
    aunque `bao status` salga con 2, y que sin respuesta no se publique nada. Hay además pruebas de `promtool` para
    las dos alertas.

## [0.5.14] - 2026-10-19

**Saga, el almacén de trazas de la plataforma** (Grafana Tempo 3.1, ADR-0008): 15 días en el SSD, consultadas
desde Odín, con una red propia para quien envía trazas. Abre el Gate 4 con su checklist y la fase 05 documentada.

### Añadido
- **Saga, el almacén de trazas de la plataforma (ADR-0008).** Es Grafana Tempo 3.1.0 en modo monolítico.
  - **Qué recibe y dónde guarda:** recibe OTLP/HTTP y guarda 15 días en el SSD (`/srv/rapido/saga`).
  - **Si falta el SSD:** sin él montado, Saga no arranca en vez de escribir en el HDD. El compose monta el directorio
    sin `create_host_path`, y `bootstrap-midgard.sh` solo lo crea si `/srv/rapido` está montado.
  - **Redes:** no publica puertos. Los emisores entran por una red propia, `yggdrasil_saga`, que no alcanza a Mimir
    ni a Odín. Odín la consulta y Mimir la lee por `heimdall`.
  - **Endurecida como el resto:** `read_only`, sin capacidades y con `mem_limit: 512m`, con `automemlimit`.
  - **En Odín:** la fuente de datos `Saga`, provisionada.
  - **Vigilancia:** el job `saga` de Mimir y la alerta `SagaCaida` (warning, 5 min), con su prueba de `promtool`.
  - **En el CI:** `tempo -config.verify` y Trivy sobre la imagen.
  - **Probado en local:** un span del gateway llegó por OTLP y se recuperó por su id. La fuente de datos de Odín
    pasó su comprobación. En reposo usa 21 MiB.
- **Gate 4 abierto y fase 05 documentada.** Nuevos documentos:
  - `.ai-dlc/gates/gate-4-deployment.md`, el checklist, en curso;
  - `docs/05-deployment/deployment.md`, con C4 Deployment, pipeline y sus controles de seguridad,
    rollback, runbook de recuperación e historial de despliegues;
  - `docs/04-testing/inventario-pruebas.md`, con todas las pruebas automatizadas y manuales vigentes,
    su trazabilidad y sus huecos.

  Salen de una auditoría documental del repositorio (con Fable), revisada contra el código.
- **Vista previa de Hliðskjálf en la tablet real** (`hlidskjalf/vista-previa.py` y `vista-previa.sh`).
  Sirve la página en desarrollo por `adb reverse`, con escenarios fijos en `hlidskjalf/escenarios/`
  (normal, wan2 caída, estrés y extremo). Un medidor en la página informa de cada fila recortada,
  tapada o fuera de la pantalla, y `probar` sale con 1 si se pierde algo. La URL de producción de la
  tablet se guarda y se restaura con `run-as`, sin imprimir el token. Es la herramienta con la que se
  midió la 0.5.13. El CI pasa ShellCheck al script y valida los escenarios.

### Cambiado
- **Documentación coherente con la v0.5.13** (auditoría documental del 2026-10-19). Los documentos
  de diseño y requisitos describían Gate 1 y no lo construido después. Ahora:
  - **Arquitectura y PRD.** El C4 incluye Thor, Bragi, ntfy y el host. Los objetivos de sondeo son 3
    ICMP cada 5 s y 3 TCP+TLS cada 15 s, y el quórum de caída es solo TLS. Las tablas recogen las
    alertas de Thor y Bragi y las recording rules que faltaban. RF04 adopta el SLO de alertado
    aceptado en Gate 3.
  - **ADR.** Notas de revisión en 0001-0006: Fenrir se integró y salió en la 0.5.3, sin el usuario
    `frigate`; ADR-0005 supersede el CD de ADR-0002; blackbox sin `NET_RAW`; 1880 y 1883 publicados.
  - **Threat model.** El DFD suma Thor, el NAS, ntfy, la tablet y `sync-host`. Se proponen T7-T10
    (bind mount del clon, respaldo con secretos, tema de ntfy, datos del host), con su DREAD
    pendiente de HITL. La clasificación de datos tiene sus filas.
  - **Cifras.** La suma de `mem_limit` es 1680 MB con Thor, y la RAM media de TA-12, 406 MiB.
  - **Nombres.** El repo del NVR es `higerotech/fenrir`. `naming.md` registra Bifröst, Hermod,
    Andvari y Bragi como servicios hermanos y deja anotado el doble uso de «Bifröst».
  - **Otros.** `repo-history.md` se regeneró: tenía 3 tags y ahora tiene 27. Las cabeceras de los
    gates quedan con su versión. `deploy/README.md` y `deploy/cd/README.md` están al día; el push de
    Nornas sí está conectado.
  - **`THROUGHPUT_RECEIVER=nornas` por defecto** en `.env.example`. Con `nulo`, una instalación nueva
    dejaba `WanThroughputBajo` en silencio. midgard ya usaba `nornas`.
- **DREAD de T7-T10 aceptado** (HITL del 2026-10-19). En T7 y T8 se corrigen las columnas de daño
  y reproducibilidad, que estaban intercambiadas; la media no cambia. El threat model añade
  «Detección en operación»: la señal de Thor y la alerta con que se medirá cada amenaza durante el
  uso. Están por implementar, y las puntuaciones se revisarán con 30 días de datos. El Gate 4 lo
  recoge como ítem pendiente.
- **Pendientes que la auditoría deja anotados** (van en PR aparte):
  - el jitter de RF01, que se implementa;
  - el umbral fijo de 800 del panel de throughput de Odín;
  - `SondaCaida`, que no cubre las sondas del hogar.

## [0.5.13] - 2026-10-19

**Hliðskjálf no pierde información en la tablet:** las alertas activas se ven siempre y, con varios
problemas a la vez, nada queda tapado sin avisar. Nombra los respaldos de Hermod y Andvari y avisa de
la batería de la tablet.

### Añadido
- **Hliðskjálf nombra los respaldos de Hermod y Andvari.** Thor ya publica los cuatro respaldos de midgard:
  Yggdrasil, Bifröst, Hermod y Andvari. Un respaldo sin nombre propio en el tablero sale con la inicial en
  mayúscula. El ejemplo de `/etc/default/yggdrasil-thor` del README trae sus respaldos y unidades.
- **Aviso de batería de la tablet en la cabecera**: si no carga, si baja con el cable puesto o si queda
  por debajo del 20 %. El WebView da `charging` con cualquier cosa enchufada: el 2026-10-19, con el USB del
  PC, decía «cargando» mientras bajaba del 17 al 15 %.

### Corregido
- **Las alertas activas no se veían en Hliðskjálf.** Con el SSD, los cuatro respaldos y 26 servicios, Host
  y Servicios llenaban la pantalla de 1280×800 y el panel de alertas, que solo recibía el alto sobrante,
  quedaba en 30 px: con `WanCaida` de wan2 activa, la tablet solo enseñaba el título. Ahora las alertas
  toman el alto de su contenido (tres como mucho, y una línea «y N alertas más») y Host se recorta por
  abajo. Para que quepa todo, las unidades del host en orden se resumen en una ficha (las que fallan
  siguen con su nombre en rojo), los respaldos van en una fila y los discos se rotulan «HDD sda».
- **Hliðskjálf ya no pierde información cuando hay varios problemas a la vez.** Probado en la tablet
  con cinco alertas, errores del SSD, el NAS al 2,8 %, un respaldo atrasado, Thor sin datos y once
  servicios caídos: antes Host perdía cuatro filas sin avisar, justo las que estaban mal. Ahora los
  respaldos tienen panel propio bajo las WAN, la frescura de Thor va en el título de Host y el detalle de
  cada disco solo nombra los contadores que no están a cero. Si aun así no cabe, Host junta lo sano en
  una fila «En orden», las alertas pasan a una línea, y un pie nombra lo que quede tapado. La línea
  «y N alertas más» dice cuáles son.
- **Una WAN caída enseñaba «0,0 ms» y velocidades vacías.** Ahora dice desde cuándo está caída, con la
  hora de su `WanCaida`, y deja la latencia y la pérdida en «—».

## [0.5.12] - 2026-10-19

**Thor y Hliðskjálf vigilan el SSD de datos de midgard y el respaldo de Bifröst**, y el segundo
despliegue de una release deja de recrear Sleipnir, Thor y sync.

### Añadido
- **Thor y Hliðskjálf vigilan el SSD de datos de midgard y el respaldo de Bifröst.** El SSD se cayó
  del bus el 2026-10-19 con SMART limpio: `smartctl` no lo habría visto.
  - **Errores del kernel por disco:** `yggdrasil_disco_errores_kernel_15m` cuenta los errores del
    enlace SATA del puerto del disco y los de E/S y ext4 del dispositivo. Probado contra el
    registro real del incidente: 55 líneas.
  - **Tipo de disco:** `yggdrasil_disco_rotacional` dice si es mecánico o SSD.
  - **Varios respaldos:** `yggdrasil_respaldo_ultimo_exito_timestamp_seconds` lleva ahora la etiqueta
    `respaldo`, uno por cada entrada de `THOR_RESPALDOS`.
  - **Alertas nuevas:** `DiscoErroresKernel` (crítica), `PuntoNoMontado` (crítica, para el SSD) y
    `RespaldoAtrasado` (30 h).
  - **Configuración del host:** la unidad lee `/etc/default/yggdrasil-thor` (discos, puntos,
    unidades y respaldos), que queda fuera del repositorio público. `THOR_DISCOS` admite rutas
    `by-id`.
  - **Hliðskjálf:** cada disco sale con su tipo, y en rojo si el kernel registra errores de su
    enlace. `/srv/rapido` se llama «SSD» y hay una fila por respaldo. El resumen conserva `respaldo`
    para la tablet que aún tenga el tablero viejo, y lee como `yggdrasil` la serie sin etiqueta de
    un Thor anterior.

### Corregido
- **El segundo despliegue de una release ya no recrea Sleipnir, Thor ni sync.** Cuando un commit
  cambia el Compose, el job `redespliegue` relanza `build` para que el receptor despliegue otra vez
  con el Compose nuevo. Ese relanzamiento reconstruía las imágenes y, como el build no es
  reproducible (las etiquetas OCI llevan la fecha), subía otro digest con el mismo tag `sha-<7>`.
  El receptor lo descargaba y recreaba todos los contenedores de esas imágenes.
  - **Cuándo pasó:** en las releases 0.5.8, 0.5.9 y 0.5.11.
  - **Efecto en la 0.5.11:** Sleipnir midió wan1 dos veces seguidas y `WanDegradada` llegó a
    `pending`.

  `build` comprueba ahora si la imagen del commit ya está en GHCR y, si está, no la reconstruye.
  El segundo despliegue solo recrea los servicios cuya configuración cambió.

## [0.5.11] - 2026-10-18

**Dos correcciones.** Thor deja de contar como servicios caídos los nombres temporales que Compose
pone durante un despliegue, y Sleipnir vuelve a medir con `speedtest-cli` e `iperf3`.

### Corregido
- **Thor ya no publica como caídos los contenedores que Compose renombra al recrear.** Durante
  un despliegue, Compose renombra el contenedor viejo a `<12 hex del id>_<nombre>` mientras
  levanta el nuevo. Una pasada de Thor en ese momento (v0.5.10, 2026-10-17) los publicó como
  servicios, y Hlidskjalf enseñó «4 servicios caídos» durante un minuto, dos de ellos
  inexistentes. Los otros dos, Ratatosk y Nornas, sí estaban recreándose. Thor descarta esos
  nombres temporales y `prueba-thor.sh` tiene el caso.
- **Sleipnir vuelve a medir en los modos `speedtest` e `iperf3`.** El hotfix 0.4.5 borró
  `medir_speedtest` y `medir_iperf3` al reescribir `medir_ookla`. Desde entonces esos dos modos
  fallaban en cada ciclo con `not found` y publicaban `medicion_ok=0`. midgard mide con `ookla`
  y no se vio afectado. Las dos funciones vuelven con dos correcciones:
  - **iperf3 ya no publica una latencia de 0 ms inventada.** No la mide, así que no publica
    `wan_throughput_latencia_ms`.
  - **Un fallo de iperf3 se detecta.** Antes el `|| return 1` miraba el estado de `jq`, no el de
    iperf3, y el error del servidor (por ejemplo, «server is busy») llega ahora al log.

  `IPERF3_SERVER` acepta `host:puerto`. Un `SLEIPNIR_MODO` desconocido ya no cae a `ookla` en
  silencio: no mide y lo dice en el log. La prueba nueva `deploy/sleipnir/tests/prueba-sleipnir.sh`
  corre el script entero en los tres modos y está en el CI.

## [0.5.10] - 2026-10-17

**Pérdida de WAN sin falsas alarmas.** La pérdida de cada WAN es la mediana de tres objetivos, así
que un destino que descarta ping ya no la infla, y la tablet distingue la pérdida que provoca la
medición de velocidad de Sleipnir.

### Cambiado
- **La pérdida de una WAN es la mediana de tres objetivos, no la media de dos.** Las sondas ICMP
  suman 208.67.222.222 (OpenDNS) a 1.1.1.1 y 8.8.8.8, y `wan:perdida_pct:5m` toma la mediana.
  Google descarta a ratos el ping a 8.8.8.8, aunque por TLS responde al 99,8 %. Con la media,
  wan1 sumó en 7 días 838 minutos de pérdida ≥ 1 % y salía en ámbar sin estar mal. La pérdida
  de un solo destino ya no cuenta como pérdida del enlace.
  - Por qué no basta con el mejor objetivo: perdía sensibilidad. Con un 5 % de pérdida real, la
    alerta disparaba en el 73 % de las simulaciones, frente al 94 % de la media. La mediana de
    tres dispara en el 97 %.
  - Se mantiene lo de TA-05: un objetivo caído del todo sigue fuera del cálculo. Si caen los
    tres, no hay serie y decide `WanCaida`, como antes.
  - Efecto en la latencia: es la media de los objetivos, y 208.67.222.222 queda a ~59 ms por
    wan1. La latencia de wan1 sube ~6 ms el día del cambio sin que el enlace cambie.
- Mimir lee Sleipnir cada 15 s en vez de cada 60 s, para que la marca de medición en curso
  llegue a tiempo.

### Añadido
- **Hlidskjalf distingue la pérdida que provoca Sleipnir.** Sleipnir satura el enlace unos 70 s
  al medir la velocidad, y las sondas ven pérdida y más latencia. Ahora publica
  `wan_throughput_medicion_en_curso{wan}` mientras mide. La tarjeta de esa WAN muestra
  «Sleipnir midiendo» y luego «tras medir la velocidad» durante los 5 min y medio en que la
  ventana arrastra la prueba, sin ponerse en ámbar por pérdida ni latencia. Una caída o una WAN
  fuera de la ruta se siguen viendo igual. Fue lo que la tablet enseñó como un 5 % en wan2 el
  2026-10-17 a las 00:28 UTC.

### Pruebas
- Nuevo `deploy/prometheus/tests/perdida.test.yml` en el CI, con cuatro casos:
  - un objetivo que pierde el 20 % no mueve la pérdida;
  - la pérdida real en los tres objetivos se ve entera;
  - un objetivo bloqueado (TA-05) no cuenta;
  - con los tres caídos no hay serie.
- La pérdida de Sleipnir en la tablet tiene su prueba de Node.

## [0.5.9] - 2026-10-16

**Hlidskjalf, el tablero de pared.** Una tablet en la pared muestra el estado de midgard: WAN,
alertas activas, salud del host y servicios, servido por Nornas con un token de solo lectura.

### Añadido
- **Hlidskjalf, el tablero de pared** (ADR-0007). Una Galaxy Tab 2 (Android 7.1, WebView
  Chromium 81, 1 GB de RAM) enseña de un vistazo el estado de midgard: cada WAN (en línea, en la
  ruta del balanceador, latencia, pérdida, última medición frente al SLO y disponibilidad de
  30 días), las alertas activas, la salud del host (disco, `/`, NAS y último respaldo) y los
  servicios del stack. La cabecera resume el peor estado, y si la tablet pierde la conexión la
  cabecera pasa a rojo y los datos se atenúan.
  - Nornas sirve la página (`GET /hlidskjalf/`, CSP por hash, sin dependencias) y el resumen
    (`GET /hlidskjalf/resumen`), que arma con **una** consulta instantánea a Mimir y las alertas
    activas de Gjallarhorn por la red interna: sin puertos nuevos y sin publicar Mimir.
  - El resumen exige `HLIDSKJALF_TOKEN`, un token de **solo lectura** distinto del del webhook;
    sin él, o con menos de 32 caracteres, responde 503.
  - `hlidskjalf/`: app Android kiosco (WebView a pantalla completa, pantalla siempre encendida,
    arranque con la tablet, opcionalmente pantalla de inicio). `construir.sh` la compila sin Gradle
    e `instalar.sh` la instala por adb y escribe la URL con el token por la entrada estándar, sin
    que pase por la línea de órdenes de ningún proceso.
  - Pruebas: `deploy/nornas/tests/hlidskjalf.test.mjs` (autorización, resumen con fuentes caídas,
    escape de HTML, CSP del flujo generado) y un job de CI que compila el APK.
- **Thor publica el estado de los servicios y el último respaldo** (`yggdrasil_servicio_ok`,
  `yggdrasil_respaldo_ultimo_exito_timestamp_seconds`), con el inventario del vigía de servicios.
  Solo se publican: el aviso sigue siendo del vigía, que no depende de la cadena de alertas.

### Cambiado
- `nornas-init` reemplaza todas las pestañas del fichero del flujo (Heimdall y Hlidskjalf), no
  solo la de Heimdall.
- `settings.js` de Nornas da a los nodos function dos funciones concretas, `consultarJson` (GET
  con tiempo máximo) y `secretoIgual` (comparación en tiempo constante), sin abrir
  `functionExternalModules`.

## [0.5.8] - 2026-10-16

**Métricas del host y paneles de 30 días que vuelven a tener datos.** Recoge la revisión de
Heimdall del 2026-10-16: Thor vigila el disco, el NAS y la ruta del balanceador, y las reglas de
SLO y disponibilidad vuelven a producir series.

### Añadido
- **Thor: métricas del host en Heimdall.** `yggdrasil-thor.timer` publica cada minuto el SMART del
  disco de midgard, el espacio de `/` y del NAS de respaldos y qué WAN tiene `wan-balancer` en la
  ruta; el servicio `thor` (httpd de la imagen de Sleipnir, solo en la red `heimdall`) lo sirve a
  Mimir. Nueve alertas en `rules/thor-alertas.yml`, entregadas por Nornas a ntfy:
  - **discrepancia con el balanceador** (acción 6 del RCA del 2026-10-06): `WanSanaFueraDeRuta`
    y `WanCaidaEnRuta`, 10 min, sin disparar cuando caen las dos WAN;
  - **disco**: `DiscoEmpeora` (sube un atributo de fallo en 24 h; los pendientes pasaron de 8 a
    16 entre el 5 y el 16 de octubre), `DiscoErroresDeCable` y `DiscoSmartFalla`;
  - **NAS** (96 % el 2026-10-16): `NasSeLlena` (tendencia de 7 días, lleno en < 14),
    `NasEspacioCritico` (< 3 %) y `NasNoMontado`;
  - `ThorSinMetricas`.
  Thor sustituye la reserva de `naming.md` para métricas del host. Pruebas: `prueba-thor.sh`
  (recolector con dobles) y `promtool test rules` de las nueve alertas.

### Cambiado
- **Nornas avisa de las discrepancias con el balanceador**: las alertas con etiqueta `wan` solo
  generaban push si el traductor las conocía por nombre.

### Corregido
- **Las reglas de 5 min dejaban sus series vacías.** Prometheus guarda la muestra de cada
  evaluación con la hora del hueco alineado del grupo y, si la evaluación arranca un instante
  antes, usa el anterior: con `interval: 5m` cada muestra nacía con más de 5 min de antigüedad,
  fuera del `lookback-delta`, y toda consulta instantánea salía vacía. Visto en midgard el
  2026-10-16 (la evaluación de las 15:59:20 se guardó como 15:54:21): los paneles «Disponibilidad
  30 días» de Odín sin datos y **`WanThroughputBajo` ciega**, porque comparaba contra un
  `wan:slo_throughput_mbps` vacío y su `for: 12h` se reiniciaba sin llegar nunca; esa semana la
  subida de wan2 bajó a 102 Mbps con un SLO de 400. El 2026-10-05 funcionaba: la alineación
  cambió con algún reinicio. Los grupos `heimdall_slo_throughput` y `heimdall_disponibilidad_30d`
  pasan a `interval: 1m`, y `deploy/prometheus/tests/intervalos.py` exige en el CI que dos
  intervalos de cualquier grupo quepan en el lookback.

## [0.5.7] - 2026-10-06

**Configuraciones renderizadas que siempre llegan al contenedor.** Hotfix del despliegue de la
`0.5.6`, que dio una `WanCaida` falsa de wan1 porque blackbox seguía leyendo una configuración
vieja.

### Corregido
- **blackbox y alertmanager montan su directorio de configuración, no el fichero.** Con
  `blackbox.yml` montado suelto, cualquier reemplazo atómico (`sed -i`, un editor, `git`) crea un
  inodo nuevo que el contenedor no ve, y las recargas siguen leyendo la versión vieja. El
  2026-10-06 un `sed -i` hecho en una prueba del guardián dejó a blackbox con la configuración de
  antes de la 0.5.6: ni las reconciliaciones del guardián ni el despliegue le llegaban, y la regla
  nueva de `wan:up` dio una `WanCaida{wan=wan1}` falsa durante 7 min. Es el mismo fallo que se
  corrigió para Prometheus en la 0.4.2. `deploy/tests/prueba-montaje-config.sh` (CI) lo reproduce
  con blackbox real y un control negativo con el fichero montado suelto.

## [0.5.6] - 2026-10-06

**Respaldo, avisos y una salud de WAN que mira TCP.** Recoge la revisión del 2026-10-05/06:
Yggdrasil no tenía respaldo, ninguna alerta llegaba a un teléfono y el incidente de wan2 del
2026-10-06 destapó tres fallos de criterio (sondas que no se reconciliaban, un único destino de
salud por WAN y ping que votaba con TCP roto).

### Añadido
- **Nornas publica las alertas en ntfy.** La salida push del flujo era un nodo `debug` también en
  producción: ninguna alerta de Heimdall llegaba a un teléfono. Ahora publica en el tema de
  `NTFY_URL` (vacía = sin push) por la API JSON de ntfy, que conserva las tildes de los títulos.
  Prioridad según la severidad (`critical` 4, `warning` 3) y la recuperación en 2.
- **Pruebas del flujo de Nornas** (`deploy/nornas/tests/`, `node --test` en el CI): avisos únicos,
  resoluciones, contrato MQTT de `WanCaida` y formato de ntfy, sin filtrar el tema.

- **Avisos por ntfy del respaldo nocturno.** Push inmediato si el respaldo falla (`OnFailure=`) y
  un vigía a las 08:00 hora de la casa que avisa si el último éxito tiene más de 26 h, para cubrir
  un temporizador que no se dispara. Va directo del host a ntfy, con el mismo tema que los avisos
  SMART (`/etc/yggdrasil-aviso.env` enlaza a `/etc/smartd-aviso.env`): la salida push de Nornas
  sigue sin conectar en producción, y el aviso no debe depender del stack que respalda.
- **Respaldo nocturno al NAS.** Hasta ahora Yggdrasil no tenía respaldo, y vive en un HDD con
  sectores pendientes y errores incorregibles. `yggdrasil-respaldo.timer` (22:30 hora de la casa,
  `Persistent=true`) archiva los seis volúmenes, el despliegue con su `.env` y la configuración
  del router en `/mnt/nas/respaldos/yggdrasil`, comprueba la suma en el NAS y conserva 14 días.
  Mimir y Odin se congelan unos 5 s para copiar una TSDB y una SQLite consistentes. Lo instala
  `bootstrap-midgard.sh` (paso 5c).
- **Observabilidad de Bragi en Heimdall** (ADR-0009 de `higerotech/bragi`): job `bragi` contra
  `bragi-metricas:9470` por la red `heimdall`, sin puertos publicados, y `rules/bragi-alertas.yml`
  con 8 alertas (caída en LAN y desde fuera, métricas ausentes, respaldo atrasado, transcodes,
  CPU anómala, memoria, y transcode coincidente con una WAN degradada). La especificación y sus
  pruebas unitarias viven en Bragi; aquí va una copia. Sin etiqueta `wan`, Nornas las entrega
  como aviso push sin cambios.
- **Bragi** reservado en `naming.md` para el servidor de medios Jellyfin, que vive en su propio repositorio (`higerotech/bragi`) por el mismo motivo que Fenrir: presupuesto de recursos y ciclo de vida propios.
- **Vigía de servicios.** `yggdrasil-vigia-servicios.timer` comprueba cada minuto los servicios
  permanentes del Compose (sacados del propio `docker-compose.yml`) y las unidades del host de las
  que depende el proyecto, y avisa por ntfy cuando uno sale de línea y cuando vuelve: dos fallos
  seguidos, un push por pasada, recordatorio cada 6 h, nada en los 10 min tras arrancar y solo
  Docker si cae Docker. Va directo del host a ntfy porque entre los vigilados está la propia
  cadena de alertas (Mimir, Gjallarhorn, Nornas). 21 pruebas con dobles en el CI.

### Cambiado
- **Un push por episodio de alerta.** Gjallarhorn reenvía el grupo entero en cada cambio y cada
  4 h, y Nornas avisaba de todas las alertas firing de cada lote. Ahora recuerda la huella de lo
  ya avisado y la olvida al resolverse (o a los 7 días, como recordatorio). Las alertas sin WAN,
  como las de Bragi, avisan también de su resolución.
- **Salud de cada WAN por mayoría de destinos TCP, igual en el balanceador, el guardián y
  Heimdall.** `wan-balancer` y `wan-watchdog` comprobaban un único ping por WAN (1.1.1.1 /
  1.0.0.1), y `wan:up` contaba 2 ICMP + 1 TLS. El 2026-10-06 el ISP2 dejó de llegar a 1.0.0.1
  (wan2 salió entera del multipath mientras Heimdall la veía sana) y, además, tenía un agujero
  negro de MTU y TCP roto hacia parte de internet mientras los ping pasaban. Ahora los tres
  deciden con la mayoría de tres comprobaciones HTTPS reales (www.gstatic.com, 1.1.1.1:443 y
  8.8.8.8:443): una WAN con ping y sin TCP queda fuera. Las sondas ICMP siguen midiendo pérdida y
  latencia. Las sondas TLS por WAN ya no fijan `server_name`: cada destino se verifica con su
  certificado (los de 1.1.1.1 y 8.8.8.8 llevan la IP como SAN). Pruebas: `promtool test rules`
  de `wan:up` con el caso del 2026-10-06 y `deploy/host/tests/prueba-quorum.sh`, que además
  exige que los tres usen los mismos destinos.

### Corregido
- **La reconciliación de sondas del guardián nunca funcionó en midgard.** `wan-watchdog.service`
  lleva `ProtectSystem=strict` sin `ReadWritePaths`, así que `/srv` era de solo lectura y
  `render.sh` no podía reescribir `blackbox.yml`. La primera vez que hizo falta, el 2026-10-06 tras
  un cambio de IP de wan2, el render falló, se agotó el cupo de remedios y `WanCaida{wan=wan2}`
  siguió disparada siendo falsa hasta arreglarlo a mano. La unidad abre ahora solo `blackbox/` y
  `alertmanager/`; el guardián llama a `render.sh --sin-recarga` (la recarga ya la hace él) y
  registra el motivo si el render falla, que antes iba a `/dev/null`.
- **Prueba de regresión en el CI**: `deploy/host/tests/prueba-sandbox-guardian.sh` ejecuta el
  render con las directivas de sandbox leídas de la propia unidad, con un control negativo que
  exige que falle sin `ReadWritePaths`. Ninguna prueba lo veía porque el CI ejecutaba `render.sh`
  fuera de systemd.

### Nota de operación
- **Recorte de MSS en `/etc/nftables.conf` de midgard** (fuera de este repo, 2026-10-06): la regla
  de clamp estaba al final de `chain forward`, detrás de los `accept`, y no se aplicaba nunca.
  Ahora va en cadenas `mangle` propias para la casa y para el host, con MSS fijo de 1440 en wan2
  por el agujero negro de MTU del ISP2. Detalle y comprobación en `deploy/host/README.md`.

## [0.5.5] - 2026-09-18

**Reglas de enrutamiento y sondas que se reconcilian solas.** Continúa la revisión del appliance
iniciada en la `0.5.4`, cerrando los casos restantes del mismo patrón: configuración que se aplica
una vez y nunca vuelve a comprobarse.

### Corregido
- **`wan-balancer` dejaba reglas de origen huérfanas en cada renovación de DHCP.** `setup_tables` borraba solo la regla de la IP **vigente** antes de reañadirla, así que las de IPs anteriores sobrevivían indefinidamente. Ocurrió el 2026-09-17: wan2 pasó de `192.168.2.8` a `.7` al recuperar carrier y las dos reglas quedaron conviviendo. Inofensivo mientras nadie tenga la IP vieja, pero si el ISP se la reasigna a otro equipo de esa red su tráfico saldría por esa WAN sin motivo, y se acumula una por renovación. `podar_reglas_origen` barre las reglas `from X lookup <tabla>` de una prioridad cuyo `X` ya no esté vigente; solo mira reglas con selector `from <dirección>`, de modo que las de `fwmark` (95) y los anclajes de clientes (90) quedan intactas.
- **IPv6 estaba peor: `setup_tables_v6` solo añadía reglas, nunca borraba.** Como `ip rule add` admite duplicados, se habría acumulado una regla idéntica **por cada vuelta del bucle, es decir cada 5 s**. Estaba dormido porque netplan lleva `dhcp6: false` y `accept-ra: false`, pero la bomba estaba puesta para el día que se active IPv6. Ahora calcula los prefijos vigentes una vez, poda los que ya no están en `lan` y borra antes de añadir.
- **Se retira el anclaje muerto de `192.168.10.21` a wan2.** Apuntaba a la MAC del NAS, pero esa MAC tiene IP fija configurada en el propio equipo (`dhcp_enable=0`, `192.168.10.30/24`) y el pool DHCP empieza en `.50`, así que **nadie tenía ni podía tener la `.21`**. La regla existía en el kernel sin coincidir con un solo paquete y el NAS nunca salió por wan2 como el anclaje pretendía. Decisión del owner: ya no aplica.

### Añadido
- **El guardián reconcilia la IP de las sondas de Heimdall.** Las sondas de blackbox llevan la IP de cada WAN **fija** en `blackbox.yml`, que solo se regenera al desplegar. Si DHCP le cambia la IP a una WAN entre despliegues, sus sondas quedan atadas a una dirección que ya no existe y fallan con `bind: Cannot assign requested address` **hasta el siguiente despliegue**; `wan-balancer` no se entera del problema porque él lee la IP en vivo. El 2026-09-17 eso mantuvo **`WanCaida{wan=wan2}` disparada 5 h 18 min siendo falso positivo**, con wan2 perfectamente sana. `reconciliar_sondas` compara cada minuto la IP viva de cada WAN con la escrita en `blackbox.yml` y, si difieren, ejecuta `render.sh` y recarga blackbox. **Corre siempre, también con la ruta y el DNS perfectos**, porque ese desfase se produce justo en ese escenario y la salida temprana del camino feliz nunca lo alcanzaría; por eso el `flock` pasa a tomarse antes de esa salida.
- `wan-watchdog.sh --estado` muestra ahora, por WAN, la IP viva frente a la de la configuración.

### Nota de operación
- El acoplamiento del guardián con Yggdrasil es deliberadamente flojo: las rutas salen por variables de entorno (`BLACKBOX_YML`, `RENDER_SH`, `RENDER_USER`) y, si los ficheros no existen, la reconciliación se salta en silencio. Aun así, `deploy/host/` es código de router que ahora conoce la disposición de Yggdrasil; lo correcto por ADR-0004 sería un temporizador propio del lado de Yggdrasil. Queda anotado como deuda consciente.

## [0.5.4] - 2026-09-17

**Resultado de la revisión completa del appliance del 2026-09-16/17.** Dos puntos ciegos de
monitorización, la causa raíz de un corte de 7 h y la corrección de una premisa errónea del SLO
de throughput.

> **Nota de versionado.** Se corta como *patch* aunque añade funcionalidad —sondas nuevas, una
> alerta nueva y un servicio de systemd nuevo—, que por SemVer estricto sería un *minor*.
> Decisión del owner (2026-09-17) para no gastar el `0.6.0`, que el proyecto reserva al cierre
> de Gate 4 por el mapeo gate→minor. Queda anotado aquí para que la desviación sea deliberada
> y no un descuido.

### Añadido
- **Sondas de la ruta real del hogar y alerta `HogarSinRuta`.** Las sondas por WAN fijan IP de origen, así que viajan por las tablas `wan1`/`wan2` que `wan-balancer` mantiene con default propio, y **ninguna pasa por `main`**, que es por donde salen la LAN, dnsmasq y los contenedores. El 2026-09-12, de 06:20 a 13:25 UTC, `main` se quedó sin ruta utilizable (dockerd: `dial udp 1.1.1.1:53: connect: network is unreachable`): **la casa estuvo 7 h sin internet, `hogar:up` valió 1 todo el rato y no se disparó ninguna alerta**. Se añaden los módulos `icmp_hogar` y `tls_hogar` (sin `source_ip_address`), los jobs `hogar_icmp`/`hogar_tls`, la recording rule `hogar:ruta_up` con el mismo quórum que `wan:up` (2 de 3), su disponibilidad a 30 días y la alerta `HogarSinRuta` (critical, `for: 2m`). Verificado en midgard reproduciendo el fallo con un `blackhole` en `main` para una IP aislada: `icmp_hogar` cayó a 0 mientras `icmp_wan1` e `icmp_wan2` seguían en 1.
- `hogar:ruta_up` es una serie **nueva**: `hogar:up` y la disponibilidad de 30 días ya reportada en Gate 3 no cambian. RF08 define la disponibilidad del hogar como "el tiempo con al menos una WAN operativa" y `hogar:up` implementa esa definición correctamente; lo que faltaba era medir el otro camino, no corregir el existente.
- **`wan-watchdog`: guardián de la ruta real de la casa** (timer de systemd, cada minuto). Segunda capa, independiente del balanceador, para lo que el arreglo de `wan-balancer` no puede cubrir: que la ruta exista y apunte bien pero el tráfico no pase, que `wan-balancer` esté colgado (systemd lo revive si muere, no si se cuelga) o que dnsmasq deje de resolver. Sondea la ruta real con `ping` **sin** `-I`, la resolución con `dig @127.0.0.1` y cada WAN por su tabla. Si `main` falla con alguna WAN sana reinicia `wan-balancer`; si la ruta va pero el DNS no, reinicia `dnsmasq`; **si las dos WAN están caídas no toca nada**, porque es un corte aguas arriba. Guardarraíles: `flock`, reintentos antes de declarar el fallo, cooldown de 3 remedios por hora y `--dry-run`/`--estado`. El camino feliz no escribe nada en el journal.
- **`deploy/host/`**: `wan-balancer.sh` y su unidad entran al repo —llevaban desde el principio solo en el appliance, sin versionar— junto al guardián, sus unidades, un `install-host.sh` idempotente y un README. No lo despliega Compose ni el receptor: es código del router.
- El guardián y `HogarSinRuta` son complementarios, no redundantes: el guardián remedia en ~20 s y la alerta tarda 2 min en dispararse, así que en el caso normal se arregla antes de avisar. Si la alerta llega igualmente, es que el remedio automático no funcionó — justo cuando quieres que te avisen.

### Cambiado
- **El SLO de throughput se evalúa contra el 80 % del nominal contratado con cada ISP, por WAN y por dirección.** La regla de Gate 0 siempre fue "el 80 % del nominal"; el "800 Mbps" era ese 80 % bajo la premisa de que ambos proveedores vendían 1 Gbps simétrico. El ISP2 es asimétrico 1:0.5 y garantiza el 80 % sobre esa condición, así que la subida de `wan2` contrata 500 Mbps y su umbral es 400. Los cuatro umbrales (`wan1` 800↓/800↑, `wan2` 800↓/400↑) dejan de estar escritos a mano en la alerta y pasan a la recording rule `wan:slo_throughput_mbps`, de modo que un cambio de plan con el proveedor sea un commit trazable. Enmendados con nota de revisión fechada el charter (0.1.3), el glosario (0.1.1) y el PRD (0.1.1), que daban por hecho el nominal simétrico. Medido en 7 d: wan1 964↓/941↑, wan2 942↓/475↑ — las cuatro series en objetivo.
- El techo de memoria de Odín (Grafana) sube de 256 a 512 MB: rozaba el 86 % del suyo (220 MiB) y un OOM kill se lleva por delante el dashboard. La suma de `mem_limit` queda en 1664 MB. No incumple RNF01, que acota la RAM **real** del stack (≤ 1.5 GB) y no la suma de techos: TA-12 midió 406 MiB de media y 554 de pico en 24 h. Aclarado en ADR-0006, la arquitectura, el baseline de configuración y el plan de pruebas, que lo enunciaban de forma ambigua.
- Las recording rules de las WAN acotan su selector de `job=~"blackbox_icmp_.*"` a `job=~"blackbox_icmp_wan[0-9]+"` (y análogo para `wan:up`). Sin ese cierre, cualquier job de sonda futuro sin etiqueta `wan` se colaría en los `by (wan)` como un grupo `wan=""`.
- El paso de ShellCheck del CI enumera los ficheros a mano: se añaden los tres de `deploy/host/`. Es la misma trampa que la 0.5.1 anotó con `promtool check rules`.

### Corregido
- **`wan-balancer` no reaplicaba nunca la ruta por defecto si el estado de las WAN no cambiaba.** `apply_default` solo corría al cambiar de estado, y como `check()` sondea con `ping -I <ip de la WAN>` —que entra por `ip rule from <ip> lookup wanN` y **nunca toca la tabla `main`**— las dos WAN podían estar sanas con `main` rota, el estado se quedaba en `11` y la ruta no se reparaba jamás. Es la causa raíz de las 7 h sin internet del 2026-09-12, que solo se arregló al reiniciar el servicio a mano porque al arrancar `up1=-1` fuerza la primera aplicación. Ahora cada vuelta verifica con `main_default_ok` que la ruta corresponde al estado y la reaplica si no; `ip route replace` es idempotente y solo se registra cuando de verdad repara algo.
- **`WanThroughputBajo` solo vigilaba la bajada** (`direccion="down"`), así que una caída de la subida de cualquiera de las dos WAN pasaba inadvertida. Ahora evalúa las dos direcciones.

### Diagnosticado, pendiente de arreglo
- **Una renovación de DHCP deja las sondas de esa WAN ciegas hasta el siguiente despliegue.** El 2026-09-17 wan2 cayó de verdad a las 14:48 UTC y al recuperar carrier DHCP le dio `192.168.2.7` en vez de `.8`. `wan-balancer` siguió el cambio (usa `wan_ip` dinámico) y la reincorporó al multipath a las 18:57, pero `blackbox.yml` lleva la IP fija renderizada por `render.sh`, que solo corre al desplegar: las sondas siguieron atándose a `.8` con `bind: Cannot assign requested address`. Resultado: **`WanCaida{wan=wan2}` encallada 5 h 18 min siendo falso positivo**, con wan2 sana. Resuelto en caliente con un re-render y recarga de blackbox; el arreglo de fondo —reconciliar la IP de forma continua, no solo al desplegar— queda pendiente.

## [0.5.3] - 2026-09-11

**Fenrir sale del appliance.** `midgard` queda como router y balanceador multi-WAN, y la plataforma deja de integrar el NVR. La decisión es de rendimiento y está medida, no intuida: sobre 24 h el appliance promedió **45,7 % de CPU con picos del 96,5 %**, y Frigate solo consumía **135 % de un núcleo — el 33,8 % de la máquina**, con el detector aportando ~30 de esos puntos. Es del orden de **tres cuartas partes de toda la carga** para un servicio que no es la función principal del equipo. Sin él, la media esperada baja al entorno del 12 %.

Lo que **no** motivó la retirada, y conviene dejarlo escrito para no repetir el diagnóstico: la memoria nunca fue un problema (máximo 38,1 % en 24 h, sin tocar swap), y el pico de E/S del 47 % de iowait que se observó era la **tormenta de arranque** tras el reinicio de las 01:17, no régimen permanente: ya asentado, el iowait era del 0,13 %.

### Eliminado
- Job de scrape `fenrir` y `rules/fenrir-alertas.yml` (las 7 alertas del NVR).
- Usuario `frigate` del broker, su ACL `readwrite frigate/#` y el secreto `MQTT_FRIGATE_PASSWORD`. El alta la hacía el propio Compose en cada arranque, así que el `passwd` se regenera sin él y no hay que tocarlo a mano.
- Los `topic read frigate/#` de `nornas` y de `iot`. **Ningún flujo de Nornas los consumía**: se provisionaron para un consumidor que nunca llegó a construirse, así que retirarlos no rompe nada.
- Referencias a Fenrir en el README de `deploy/`, en los comentarios del Compose y de `mosquitto.conf`, y el fichero de reglas de la lista explícita del CI.

> Los datos del NVR —35 GB de grabaciones y `frigate.db` con 1.185 eventos— se borraron del appliance por decisión expresa. No existía copia: el respaldo al NAS de ADR-0006 nunca llegó a montarse. Queda anotado aquí porque es irreversible y porque explica por qué no hay nada que restaurar.

## [0.5.2] - 2026-09-09

Hotfix sobre la 0.5.1, a partir de lo que se vio en las primeras horas de las alertas del NVR ya en marcha.

### Añadido
- `CpuNvrAlta`: CPU del appliance por encima del 70 % durante 15 min. Vigila `frigate_cpu_usage_percent{pid="frigate.full_system"}`, que es la **única** serie de esa métrica en escala 0-100 del sistema entero; las demás son por proceso y relativas a **un** núcleo —el detector marca 195,7 en un i3 de 4 hilos—, así que un umbral de 70 sobre ellas estaría disparando siempre. El umbral es 70 y no el 50 que fija RNF01 del NVR porque la media real ya es del 56 % (medido: min 40,8 / media 56,4 / max 75,0 en una hora): a 50 la alerta estaría encendida a todas horas y no distinguiría «seguimos fuera de presupuesto» de «esto ha empeorado». El incumplimiento de RNF01 se sigue por la medición del gate, no por una alerta permanentemente en rojo. La anotación manda comparar con la serie del detector antes de tocar nada: si la CPU de la máquina sube y la del detector no, el NVR es la víctima y no la causa.

### Cambiado
- `DetectorSaturado` pasa de `frigate_skipped_fps > 0` instantáneo a `avg_over_time(frigate_skipped_fps[10m]) > 0.5`, con `for: 10m`. El cambio se hizo esperando que dejara de saltar por picos —y **sigue saltando**: la media de 10 min es 0,88 en `cam_01` y 0,685 en `cam_02`, y en media hora **el 10-11 % de los frames no se analizan** en ambas cámaras. No era ruido: el detector por CPU del NVR está saturado de forma sostenida. La regla nueva es mejor igualmente, porque ahora distingue una racha de una saturación real, pero el diagnóstico no cambia y sigue en el tejado del proyecto del NVR (bajar `detect.fps` o acotar con `cpuset`).

## [0.5.1] - 2026-09-09

Hotfix sobre la 0.5.0. Fenrir (el NVR, `higerotech/fenrir`) llevaba desde su despliegue **sin ninguna alerta activa**: su job de scrape y sus reglas existían como especificación en aquel repositorio, pero nunca llegaron a este `prometheus.yml`. Va por hotfix y no por `develop` porque la alerta de disco protege al appliance entero, no solo al vídeo: `/srv` comparte volumen con la raíz y el grupo de volúmenes no tiene espacio libre (`VFree = 0`), así que llenarlo degrada también el enrutamiento.

### Añadido
- Job `fenrir` en `scrape_configs`: `/api/metrics` sobre `fenrir:5000` por `yggdrasil_heimdall`, a 30 s en vez de los 15 del resto (el NVR cambia despacio y el appliance ya va al 52 % de CPU sostenida). El 5000 no está publicado en ninguna interfaz y se alcanza solo por esa red, que es lo que mantiene intacta la amenaza T6 del NVR. Comprobado antes de escribirlo: el endpoint responde, manda `Content-Type: text/plain; version=0.0.4` —así que no necesita el `fallback_scrape_protocol` de Sleipnir— y publica las cinco métricas que usan las reglas.
- `rules/fenrir-alertas.yml`: 6 alertas del NVR (caída, cámara sin frames, disco al 85 % y al 92 %, detector saturado y memoria). Copia instalada; la especificación vive en el repositorio del NVR para que los umbrales sigan trazados a sus requisitos.
- El paso de `promtool check rules` del CI enumera los ficheros a mano: se añade el nuevo a esa lista, aunque `check config` ya lo cubra por el glob de `rule_files`.

### Corregido
- Las alertas de disco del NVR medían también la RAM. `frigate_storage_*` publica cuatro series y dos no son disco: `/tmp/cache` (tmpfs, 954 MB) y `/dev/shm` (128 MB). Sin filtrar, un `/dev/shm` al 90 % —115 MB, nada— habría anunciado «Almacenamiento del NVR al 90 %» y mandado al runbook del disco, con el problema real siendo de memoria. Se acota con `storage=~"/media/frigate/.*"`. Medido en este Prometheus: recordings 7,11 %, clips 7,11 %, tmpfs 4,05 %, shm 10,47 %. El defecto no se ve leyendo el YAML; hace falta ejecutar la expresión contra datos reales.
- Las anotaciones de esas alertas pasan de `summary` a `resumen`. El nodo *Alertmanager → estados MQTT* de Nornas hace `aviso(titulo, an.resumen)` para toda alerta sin etiqueta `wan`, que son las seis: con `summary` la notificación habría llegado con el cuerpo vacío —ni falla ni avisa—. Queda una arista conocida: el título dirá `Heimdall: FenrirCaido`, porque el prefijo está fijo en esa función del flujo.

### Observado al instalarlo
- `DetectorSaturado` entró en `pending` en la primera evaluación, y no es ruido: `frigate_skipped_fps` marcaba 0,2 en `cam_01` con picos de 2,2 en 15 minutos. Es el canario de T2 del NVR y llega junto al 52 % de CPU sostenida sobre su presupuesto del 50 %. La decisión (bajar `detect.fps` o acotar con `cpuset`) es del proyecto del NVR, no de la plataforma.

## [0.5.0] - 2026-09-09

**Cierre del Gate 3 (Testing).** Heimdall queda verificado sobre el sistema real desplegado en midgard.
No cambia código: recoge la evidencia de la verificación y aprueba el plan de pruebas. Las correcciones
que salieron de las pruebas se publicaron durante el gate, de la `0.4.3` a la `0.4.9`.

### Verificado
- **Aceptación (TA-01 a TA-14)**: despliegue continuo, sondeo por WAN, detección de caída y de degradación, quórum frente a falsos positivos, estado retenido en MQTT, throughput calibrado, dashboard y retención de 30 días, percentiles, disponibilidad, aptitud para llamadas, consumo de recursos, arranque tras corte de corriente y ciclo completo de recuperación.
- **Seguridad (TS-01 a TS-10)**: barrido completo de puertos, autenticación de Odín y Nornas, listas de control de acceso de Ratatosk, webhook con Bearer, contenedores sin root, secretos fuera del repositorio y digests de imágenes. Matriz OWASP del PRD verificada con casos, no declarada.
- **Rendimiento (RNF01)**: 26 muestras horarias sobre 24 h 31 min; 406 MiB de RAM de media y 554 en el pico, frente al límite de 1536; CPU de los contenedores en el 1,8 % de media, frente al 10 %.
- **Transiciones de `EnlaceWan`**: verificadas, incluida la inválida (Caído nunca pasa a Saludable sin Recuperando).

### Desviaciones aceptadas
- La latencia de alertado medida (≈ 2,5 min para una caída y ≈ 6 min para una degradación) pasa a ser el SLO, en lugar de los 2 y 5 min que fijaba el plan: la histéresis de `for` evita falsos positivos.
- TS-02 queda con evidencia indirecta del cortafuegos, a falta de un punto de observación fuera de la red.
- El riesgo del adaptador USB de `wan2` queda aceptado con vigilancia: en marcha es estable, pero la enumeración USB del arranque puede dejarlo colgado.
- Limitación conocida: Heimdall no registra su propia caída, porque sin muestras las reglas de disponibilidad no ven esa ventana.

## [0.4.9] - 2026-09-08

Hotfix sobre la 0.4.8, a partir de TA-13 (reinicio del appliance) en Gate 3.

### Añadido
- `yggdrasil-arranque.service`: unidad de systemd que converge el stack (`compose up -d`) tras cada arranque del appliance, con la etiqueta que el receptor dejó desplegada. `bootstrap-midgard.sh` la instala y la habilita.

### Corregido
- Tras el reinicio del 2026-09-08, Gjallarhorn no volvió a arrancar: Docker lo marcó `exited` (código 255) mientras restauraba los contenedores y no le reaplicó `restart: unless-stopped`, así que el sistema de alertas quedó caído sin que nada lo notificara. La unidad de arranque converge el proyecto entero sea cual sea el estado en que quedó cada contenedor.

## [0.4.8] - 2026-09-08

Hotfix sobre la 0.4.7, a partir de TS-07 (elevación de privilegios) en Gate 3.

### Corregido
- Huginn y Muninn (blackbox_exporter) corrían como root con `CAP_NET_RAW`. Pasan a `nobody` (65534) sin capacidades: el ICMP usa sockets no privilegiados, que el host permite con `net.ipv4.ping_group_range` (bootstrap). Verificado en midgard con un contenedor de prueba (`probe_success` 1 por `wan1`).

## [0.4.7] - 2026-09-08

Hotfix sobre la 0.4.6, a partir de TA-04 y TA-14 en Gate 3.

### Corregido
- Tras recuperarse una WAN, la ventana de 5 min de `wan:perdida_pct:5m` arrastraba los fallos del corte y `WanDegradada` y `WanNoAptaLlamadas` disparaban ≈ 5 min después de la recuperación con el enlace ya sano, lo que dejaba el estado en `degradado` en vez de `saludable`. Ambas alertas exigen ahora que la WAN lleve toda la ventana arriba (`min_over_time(wan:up[5m]) == 1`).
- Gjallarhorn agrupa con `group_interval: 1m` (antes 5m): las notificaciones de resolución salían en el siguiente lote del grupo y el estado publicado en MQTT iba hasta 5 min por detrás de Mimir (Recuperando llegó 3 min 15 s después de resolverse `WanCaida`).

## [0.4.6] - 2026-09-08

Hotfix sobre la 0.4.5, a partir de TA-05 (quórum) en Gate 3.

### Corregido
- `wan:perdida_pct:5m` promediaba los fallos de todos los objetivos ICMP, así que un solo objetivo inalcanzable (1.1.1.1 bloqueado en TA-05) contaba como 50 % de pérdida y disparaba `WanDegradada` y `WanNoAptaLlamadas` en ambas WAN aunque el enlace estuviera sano. La regla excluye ahora los objetivos sin ninguna respuesta en la ventana: la pérdida del enlace es la de los objetivos que sí responden.
- Las sondas ICMP se raspan cada 5 s (antes 15 s): con 120 muestras por ventana de 5 min la resolución de la pérdida es 0,8 %, coherente con el umbral del 1 %; a 15 s era 2,5 %.

## [0.4.5] - 2026-09-08

Hotfix sobre la 0.4.4, tras la primera medición de Sleipnir `0.2.0` en producción.

### Corregido
- Sleipnir `0.2.1`: la elección automática de servidor de Ookla puede caer en uno lento y simular una degradación del ISP (wan2: 312 Mbps contra M21 Telecom frente a 941 contra Thundernet y 939 contra MDS Telecom en el mismo minuto). `OOKLA_SERVER_ID` admite ahora varios IDs separados por coma: la sonda mide contra cada uno y publica el máximo por sentido y el mejor ping, y registra cada servidor en el log. Los mensajes de la sonda van a stderr para no contaminar el resultado capturado.

## [0.4.4] - 2026-09-08

Hotfix de CI/CD sobre la 0.4.3.

### Corregido
- El relanzamiento automático del workflow `build` (segundo despliegue cuando cambia el Compose) compartía grupo de concurrencia con la ejecución del push y la cancelaba en su último segundo: el `workflow_run` del push llegaba como `cancelled`, el receptor lo ignoraba y solo se desplegaba una vez, con el Compose anterior. El grupo incluye ahora el evento, así que ambas ejecuciones terminan y el receptor despliega dos veces como estaba previsto.

## [0.4.3] - 2026-09-07

Release de corrección desde `develop` durante Gate 3: las lecturas de throughput de Heimdall eran inservibles (calibración de TA-07).

### Corregido
- Sleipnir `0.2.0` mide con la CLI oficial de Ookla (`1.2.0`, pineada por sha256 en el `Dockerfile`) ligada a cada interfaz WAN; `speedtest-cli` daba 76–188 Mbps de bajada en el i3 frente a los 939 Mbps reales medidos en TA-07. `SLEIPNIR_MODO` pasa a `ookla` por defecto (`speedtest` e `iperf3` siguen disponibles) y `OOKLA_SERVER_ID` permite fijar servidor.
- Evidencia de la calibración de TA-07 en `docs/04-testing/test-plan.md`: techo de la cadena de medición ≥ 939 Mbps, dos muestras por WAN; `wan1` degradada a 16 Mbps de bajada tras la caída del ISP1 y recuperada a 940/940 a las 18:58 UTC.

### CI/CD
- El workflow `build` se relanza a sí mismo cuando un push a `main` cambia el Compose, para que el receptor despliegue una segunda vez con el Compose ya actualizado (PR #21).

## [0.4.2] - 2026-09-07

Hotfix sobre la 0.4.1, a partir de lo observado al desplegarla en midgard.

### Corregido
- Mimir no aplicaba `prometheus.yml` nuevo al recargar: el fichero estaba montado suelto y el checkout de `sync-host` lo sustituye por un inodo nuevo que el bind mount no sigue. Se monta el directorio `prometheus/` completo. Ratatosk y Nornas, cuyos ficheros de configuración solo se leen al arrancar, se recrean en cada despliegue del CD (`YGG_REV`).
- `nornas-init` se ejecutaba en paralelo a `sync-host` y leía el flujo del checkout anterior, así que la 0.4.1 no actualizó la pestaña de Heimdall. `sync-host` deja el marcador `deploy/.sync/rev` y `nornas-init` espera a que coincida con `IMAGE_TAG` antes de importar.
- Flujo de Nornas: si `WanDegradada` seguía activa al terminar la recuperación de una caída, el enlace quedaba `saludable` hasta el siguiente aviso (4 h). El traductor recuerda la degradación por WAN y al salir de Recuperando publica `degradado` cuando corresponde.

## [0.4.1] - 2026-09-07

Hotfix sobre la 0.4.0 tras la primera caída real detectada por Heimdall (ISP1, 2026-09-07 13:05 UTC).

### Corregido
- Flujo de Nornas: el estado del hogar se calculaba solo con las WAN de las que ya había habido alertas, así que la caída de `wan1` publicó `midgard/hogar/internet/estado = caido` con `wan2` sana. Ahora considera todas las WAN (`YGG_WANS`, por defecto `wan1,wan2`) y una WAN sin alertas cuenta como saludable. Una WAN caída publica además `apto_llamadas = no`, y al volver a saludable se restaura el último valor conocido del indicador.
- Mimir no ingería las métricas de Sleipnir: Prometheus 3 rechaza un objetivo sin `Content-Type` y busybox httpd no lo envía (`SondaCaida` activa desde el primer despliegue). El job `sleipnir` declara `fallback_scrape_protocol: PrometheusText0.0.4`.
- `nornas-init` reimporta la pestaña Heimdall cuando cambia la revisión del flujo (hash de `src/*.js` en el nodo de pestaña), conservando las demás pestañas del editor; antes solo importaba la primera vez.

## [0.4.0] - 2026-09-05

Release de arranque de Gate 3. Lleva a `main` el despliegue continuo (ADR-0005) y los servicios de plataforma Ratatosk y Nornas (ADR-0006); su primer despliegue automático en midgard es la primera prueba de aceptación (TA-01). Con esta release la convención de versiones se desplaza un menor: el cierre de Gate 3 cortará 0.5.0.

### Añadido
- Workflow `build`: si el commit cambia `docker-compose*.yml`, se relanza a sí mismo por `workflow_dispatch` para que el receptor haga un segundo despliegue con el Compose nuevo (compensa el desfase de un despliegue del Compose dentro del clon, observado al desplegar la 0.4.2). Documentado en `deploy/cd/README.md`.
- Gate 3 abierto: `docs/04-testing/test-plan.md` (estrategia en cuatro capas, alcance sobre la arquitectura, trazabilidad requisito ↔ prueba con `verifies`, casos TA-01..TA-14, seguridad TS-01..TS-10, transiciones de estado, calibración del techo de throughput y criterio de salida) y checklist `.ai-dlc/gates/gate-3-testing.md`.
- ADR-0006: Ratatosk (Mosquitto 2.0.22) y Nornas (Node-RED 4.1.14) pasan a ser servicios de plataforma desplegados por el Compose de Yggdrasil, ya que no existía broker ni Node-RED en midgard. Ratatosk con `allow_anonymous false`, una credencial por cliente (`nornas`, `frigate`, `iot`) generada al arrancar desde `.env`, ACL por tópico (control T3 propio) y límites; Nornas con editor autenticado (`settings.js`), secreto de credenciales estable y webhook de Alertmanager por la red interna; `nornas-init` importa el flujo de Heimdall por la Admin API e inyecta las credenciales MQTT. RNF01 sube a 1408 MB. El bootstrap completa las claves nuevas de `.env` sin tocar las existentes.
- ADR-0005: despliegue continuo con el receptor de `higerotech/despliegue-continuo` (supersede la sección CD de ADR-0002). `build-and-push.yml` publica `yggdrasil-sleipnir` y `yggdrasil-sync` en GHCR con tag `sha-<7>`; `deploy/docker-compose.cd.yml` añade las tareas `sync-host` (checkout del commit, render con las IPs de las WAN, recarga de blackbox) y `sync-net` (recarga de Mimir y Gjallarhorn); `deploy/cd/bootstrap-midgard.sh` prepara el appliance con sudo (sysctl, clon como `deploy`, `.env`, inventario del receptor) y `deploy/cd/README.md` documenta webhook, operación y rollback.
- Prerrequisitos verificados en midgard el 2026-09-05: Ubuntu 24.04.4, Docker 29.8 y Compose v5.5, `wan1`/`wan2` con `ip rule from`, docker0 en 172.17.0.1, receptor sano con túnel; pendientes `ping_group_range`, reglas nftables y la ausencia de Node-RED y Mosquitto (Nornas y Ratatosk).

### Cambiado
- `render.sh` tolera una WAN sin IPv4: conserva la última IP renderizada con aviso y solo aborta si no hay render previo. Motivado por la caída de `wan2` en midgard durante el bootstrap del 2026-09-05.
- Charter (0.1.2), PRD, `architecture.md` (C4 Container y notas), `threat-model.md` (filas MQTT y Node-RED, T3) y clasificación de datos: Ratatosk y Nornas dejan de ser "existentes" y pasan a servicios propios; `NORNAS_URL` por defecto `http://nornas:1880/heimdall/alertas`; Gjallarhorn ya no necesita `host.docker.internal`.
- Imagen de Sleipnir pasa a `ghcr.io/higerotech/yggdrasil-sleipnir` con `IMAGE_TAG`; `deploy/scripts/deploy.sh` queda como vía manual de contingencia.

## [0.3.0] - 2026-09-05

Gate 2 (Implementation) aprobado. Primeros artefactos ejecutables en `deploy/`, validados con las herramientas oficiales en local y en CI; imágenes re-pineadas tras el triaje de CVEs; documentación de la fase 03 con el historial del repo derivado del git log.

### Añadido
- Gate 2 (Implementation) aprobado por el owner: `config-baseline.md` y `cadena-suministro.md` en `approved`; política de triaje de CVEs y residual aceptados.
- `docs/03-implementation/config-baseline.md` (inventario de artefactos y trazabilidad a requisitos, pipeline de render, desviaciones respecto a Gate 1, validación equivalente a SAST, cadena de suministro, secretos y riesgos que entran a Gate 3, con `classDiagram` del traductor de Nornas), `cadena-suministro.md` (triaje de CVEs, residual por imagen, exposición real y política propuesta) y `repo-history.md` generado desde el git log con `scripts/generar-historial.py` (vistas de `main` y `develop`, tabla tag ↔ versión ↔ decisión y bitácora).
- `scripts/gitgraph_from_log.py` (copiado del skill AI-DLC) y `scripts/generar-historial.py`; escaneo semanal programado de Trivy en `validar-configs.yml`; historial de pines en `deploy/imagenes.md`.
- `deploy/docker-compose.yml` (Gate 2): Huginn y Muninn (blackbox_exporter v0.27.0, host-mode, `cap_add NET_RAW`), Sleipnir (imagen propia sobre alpine 3.22 pineada por digest), Mimir (Prometheus v3.5.0, retención 30 d), Gjallarhorn (Alertmanager v0.28.1) y Odín (Grafana 12.1.1, único puerto publicado en la IP LAN); `mem_limit` total 1088 MB (RNF01), `restart: unless-stopped` (RNF02), `no-new-privileges` y rootfs de solo lectura.
- Configuraciones del contrato: módulos blackbox `icmp_wan1/2` y `tls_wan1/2` con `source_ip_address`; scrape de Prometheus cada 15 s; recording rules `wan:perdida_pct:5m`, `wan:latencia_p90|p95|p99:5m`, `wan:up`, `hogar:up`, `wan:apto_llamadas`, `wan:disponibilidad:30d`, `hogar:disponibilidad:30d`; alertas `WanCaida`, `WanDegradada`, `WanNoAptaLlamadas`, `WanThroughputBajo`, `SleipnirSinMedicion`, `SondaCaida`; Alertmanager con inhibición por WAN, webhook Bearer a Nornas y receptor nulo para throughput hasta calibrar; datasource y dashboard `heimdall-sla` provisionados en Grafana.
- Sleipnir: `sleipnir.sh` alterna wan1/wan2 cada 3 h (speedtest-cli o iperf3 con bind a la IP de la WAN) y publica `wan_throughput_mbps{wan,direccion}` por HTTP en :9469.
- Flujo de Nornas `heimdall-alertas.json`: valida el token Bearer, traduce el webhook a `midgard/wan/<id>/estado`, `midgard/wan/<id>/apto_llamadas`, `midgard/hogar/internet/estado` y `midgard/wan/<id>/alerta`, y resuelve Recuperando → Saludable tras 5 min.
- `deploy/scripts/render.sh` (plantillas + IPs de las WAN + recarga en caliente) y `deploy/scripts/deploy.sh` (despliegue idempotente, ADR-0002); `deploy/.env.example` en rango RFC 5737; `deploy/README.md`; `deploy/imagenes.md` con digests.
- Workflow `validar-configs.yml`: compose config, promtool, amtool, blackbox `--config.check`, JSON, build de Sleipnir, ShellCheck, gitleaks y Trivy (informe) en cada PR que toque `deploy/`.
- Checklist `.ai-dlc/gates/gate-2-implementation.md`.

### Cambiado
- Imágenes re-pineadas tras el triaje de Trivy: Prometheus `v3.5.0` → `v3.14.0`, Alertmanager `v0.28.1` → `v0.34.0`, blackbox_exporter `v0.27.0` → `v0.28.0`, Grafana `12.1.1` → `12.4.10`; Sleipnir `0.1.1` con `apk upgrade` en el build. Los hallazgos HIGH/CRITICAL pasan de 41 a 123 por imagen a entre 2 y 6, salvo blackbox (40, sin release más nueva; mitigado por red).
- Desviaciones de implementación reflejadas en `architecture.md` (contenedor Sleipnir, `Rel` de scrape, quórum con TCP+TLS, percentiles sobre `probe_icmp_duration_seconds{phase="rtt"}`, métricas y alertas nuevas en los contratos), `threat-model.md` (T4 con token Bearer), PRD (host `www.gstatic.com:443` por TCP+TLS), glosario y ADR-0003 (nota de implementación sobre docker0): tercer objetivo por TCP+TLS (el prober http de blackbox no fija IP de origen); token en cabecera `Authorization: Bearer` en vez de URL; Sleipnir sirve su textfile por HTTP en lugar de node_exporter; latencia desde `probe_icmp_duration_seconds{phase="rtt"}`; puertos host-mode ligados a la IP de docker0.

## [0.2.0] - 2026-09-05

Gate 1 (Design) aprobado. Arquitectura y threat model en `approved`; los cuatro ADR en `accepted`; hallazgos de la revisión inicial cerrados.

### Cambiado
- ADR-0001 (stack de métricas) y ADR-0003 (host-mode selectivo) pasan a `accepted` (2026-09-05). Charter (0.1.1) y `naming.md`: Frigate/Fenrir se desarrolla en el proyecto independiente `nvr-frigate`; el presupuesto de RAM de Yggdrasil queda en ≤ 1.5 GB sin depender de Frigate.
- Gates movidos de `docs/gates/` a `.ai-dlc/gates/` y ADR de `docs/02-design/adr/` a `docs/00-project/adr/`, alineando el árbol con el estándar AI-DLC polyrepo de la organización.
- C4 Container: el boundary de la plataforma pasa a id `yggdrasil` y Heimdall queda como `Container_Boundary` propio, de modo que el id `heimdall` designa lo mismo que en el C4 Context; el slot de tecnología muestra Prometheus, Alertmanager, Grafana y Node-RED en vez de "Docker".
- Diagramas: "Odín" con acento en los DFD del PRD y del threat model; los elementos del requirementDiagram usan los nombres nórdicos (Huginn y Muninn, Sleipnir, Mimir, Gjallarhorn, Odín, Nornas) con la tecnología en `type`, según `naming.md`.

### Añadido
- Gate 1 (Design) aprobado por el owner: `architecture.md` y `threat-model.md` pasan a `approved`; ADR-0001..0004 en `accepted`.
- ADR-0004: frontera con Fenrir (Frigate NVR), proyecto independiente con métricas y monitoreo propios; la integración con Yggdrasil será una feature futura con su propio PRD y ADR.
- Trazabilidad de RF02, RF06, RF09 y RNF02 en el requirementDiagram del PRD; todos los requisitos quedan enlazados a un componente que los satisface. El diagrama se divide en dos vistas (medición y alertado; observabilidad, no funcionales y seguridad) para respetar el límite de ~12 nodos y renderizar legible.

## [0.1.0] - 2026-09-05

Primer corte: Gate 0 (Requirements) aprobado. Incluye las fases 00 y 01 en `approved` y los borradores de la fase 02 (arquitectura, threat model y ADRs) camino a Gate 1.

### Cambiado
- Plataforma renombrada a **Yggdrasil** (antes propuesta genérica); convención de nombres nórdica en `docs/00-project/naming.md`.
- Servicio F-001 renombrado **Heimdall**; componentes: Huginn/Muninn (sondas), Sleipnir (throughput), Mimir (Prometheus), Gjallarhorn (Alertmanager), Odín (Grafana), Nornas (Node-RED), Ratatosk (MQTT).
- Espacio de tópicos MQTT: `casa/...` → `midgard/...`.
- SLI de latencia: de p95 único a percentiles p90, p95 y p99 por WAN (glosario, PRD, contratos de métricas); el umbral SLO de pérdida queda confirmado en 1 % sobre 5 min (Gate 0 parcialmente validado el 2026-09-05).
- Umbrales SLO cerrados por el owner (2026-09-05): p95 < 500 ms para servicios estándar (Degradado) y < 200 ms para llamadas críticas (indicador `apto_llamadas`); throughput ≥ 800 Mbps por WAN (80 % del nominal). Máquina de estados, glosario y charter actualizados.

### Añadido
- Gate 0 (Requirements) aprobado por el owner: hosts de sondeo confirmados (1.1.1.1, 8.8.8.8, `https://www.gstatic.com/generate_204`); charter, glosario, clasificación de datos y PRD pasan a `approved`.
- `naming.md` con topología de mundos (Midgard edge, Asgard nube, Bifrost) y nombres reservados.
- Charter, glosario y clasificación de datos (fase 00).
- PRD `isp-sla-monitor` con escenarios de abuso, C4 Context, journey, requirementDiagram y threat assessment inicial (fase 01, hacia Gate 0).
- `architecture.md` con C4 Container, sequence, state, ER, class y contratos de métricas/MQTT (fase 02, hacia Gate 1).
- `threat-model.md` STRIDE + DREAD del servicio de monitoreo SLA.
- ADR-0001 (stack de métricas, proposed), ADR-0002 (placement en appliance local), ADR-0003 (network_mode host para sondas).
- `LICENSE` con la GNU Affero General Public License v3.0 (`AGPL-3.0`); referencia en README y charter.
- RF07 y tabla de umbrales SLO en el PRD; recording rules `wan:latencia_p90|p95|p99:5m` en `architecture.md`.
- Propósito del sondeo, RF08 (disponibilidad mensual por WAN y del hogar) y RF09 (SLO de throughput) en el PRD; hosts de sondeo por defecto; escenarios de latencia alta sin pérdida, cierre de mes y falso positivo de throughput.
- Contratos nuevos en `architecture.md`: recording rules `wan:up`, `hogar:up`, `wan:disponibilidad:30d`, `hogar:disponibilidad:30d` y `wan:apto_llamadas`; tabla de alertas (`WanCaida`, `WanDegradada`, `WanNoAptaLlamadas`, `WanThroughputBajo`); tópicos MQTT `midgard/wan/<id>/apto_llamadas` y `midgard/hogar/internet/estado`.
- Repositorio publicado en `higerotech/yggdrasil` con GitFlow: `README.md`, `.gitignore`, `.gitattributes` (LF) y `gitflow-guard.yml`; `main` protegida por ruleset (solo PR con merge commit desde `develop`, `release/*` o `hotfix/*`).

[Unreleased]: https://github.com/higerotech/yggdrasil/compare/v0.5.22...HEAD
[0.5.22]: https://github.com/higerotech/yggdrasil/compare/v0.5.21...v0.5.22
[0.5.21]: https://github.com/higerotech/yggdrasil/compare/v0.5.20...v0.5.21
[0.5.20]: https://github.com/higerotech/yggdrasil/compare/v0.5.19...v0.5.20
[0.5.19]: https://github.com/higerotech/yggdrasil/compare/v0.5.18...v0.5.19
[0.5.18]: https://github.com/higerotech/yggdrasil/compare/v0.5.17...v0.5.18
[0.5.17]: https://github.com/higerotech/yggdrasil/compare/v0.5.16...v0.5.17
[0.5.16]: https://github.com/higerotech/yggdrasil/compare/v0.5.15...v0.5.16
[0.5.15]: https://github.com/higerotech/yggdrasil/compare/v0.5.14...v0.5.15
[0.5.14]: https://github.com/higerotech/yggdrasil/compare/v0.5.13...v0.5.14
[0.5.13]: https://github.com/higerotech/yggdrasil/compare/v0.5.12...v0.5.13
[0.5.12]: https://github.com/higerotech/yggdrasil/compare/v0.5.11...v0.5.12
[0.5.11]: https://github.com/higerotech/yggdrasil/compare/v0.5.10...v0.5.11
[0.5.10]: https://github.com/higerotech/yggdrasil/compare/v0.5.9...v0.5.10
[0.5.9]: https://github.com/higerotech/yggdrasil/compare/v0.5.8...v0.5.9
[0.5.8]: https://github.com/higerotech/yggdrasil/compare/v0.5.7...v0.5.8
[0.5.7]: https://github.com/higerotech/yggdrasil/compare/v0.5.6...v0.5.7
[0.5.6]: https://github.com/higerotech/yggdrasil/compare/v0.5.5...v0.5.6
[0.5.5]: https://github.com/higerotech/yggdrasil/compare/v0.5.4...v0.5.5
[0.5.4]: https://github.com/higerotech/yggdrasil/compare/v0.5.3...v0.5.4
[0.5.3]: https://github.com/higerotech/yggdrasil/compare/v0.5.2...v0.5.3
[0.5.2]: https://github.com/higerotech/yggdrasil/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/higerotech/yggdrasil/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/higerotech/yggdrasil/compare/v0.4.9...v0.5.0
[0.4.9]: https://github.com/higerotech/yggdrasil/compare/v0.4.8...v0.4.9
[0.4.8]: https://github.com/higerotech/yggdrasil/compare/v0.4.7...v0.4.8
[0.4.7]: https://github.com/higerotech/yggdrasil/compare/v0.4.6...v0.4.7
[0.4.6]: https://github.com/higerotech/yggdrasil/compare/v0.4.5...v0.4.6
[0.4.5]: https://github.com/higerotech/yggdrasil/compare/v0.4.4...v0.4.5
[0.4.4]: https://github.com/higerotech/yggdrasil/compare/v0.4.3...v0.4.4
[0.4.3]: https://github.com/higerotech/yggdrasil/compare/v0.4.2...v0.4.3
[0.4.2]: https://github.com/higerotech/yggdrasil/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/higerotech/yggdrasil/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/higerotech/yggdrasil/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/higerotech/yggdrasil/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/higerotech/yggdrasil/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/higerotech/yggdrasil/releases/tag/v0.1.0
