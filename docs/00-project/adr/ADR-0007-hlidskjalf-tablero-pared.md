# ADR-0007: Hlidskjalf, tablero de pared servido por Nornas en una tablet kiosco

* **Estado:** accepted
* **Fecha:** 2026-10-16
* **Decisores:** Jeremi
* **Fase AI-DLC:** 02-design
* **Versión:** 1.0.0
* **ID:** ADR-0007
* **Supersede / Superseded-by:** —
* **Controles OWASP afectados:** A01 (resumen de solo lectura con token propio), A03 (todo texto del servidor se escapa; CSP por hash), A05 (sin puertos nuevos; Mimir y Gjallarhorn siguen sin publicarse)

## Contexto
Se quiere ver el estado de midgard de un vistazo, en una tablet fija en la pared, sin abrir Odín
ni esperar a un push. La tablet disponible es una Samsung Galaxy Tab 2 10.1 (GT-P5100) con
LineageOS 14.1 no oficial: Android 7.1.2, ARMv7 de dos núcleos a 1 GHz, 916 MB de RAM y un WebView
Chromium 81 sin servicios de Google. Está en la Wi-Fi de la casa, en otra subred, y llega a midgard
por el router; desde ahí solo ve los puertos publicados en la IP LAN: Odín 3000, Nornas 1880 y
Ratatosk 1883. Mimir (9090) y Gjallarhorn (9093) no se publican (T2).

Lo que debe mostrar: estado de cada WAN (y si coincide con la ruta del balanceador), alertas
activas, salud del host (disco, NAS, respaldo) y servicios del stack. Los servicios y el respaldo
no estaban en Mimir: el vigía de servicios los mira en el host y avisa directo a ntfy.

## Decisión
- **Nornas sirve el tablero**, en una pestaña nueva de su flujo (`Hlidskjalf · tablero de pared`):
  - `GET /hlidskjalf/` devuelve una página estática (HTML, CSS y JS en línea, sin dependencias)
    con `Content-Security-Policy` que solo admite esos dos bloques por su hash SHA-256;
  - `GET /hlidskjalf/resumen` hace **una** consulta instantánea a Mimir con todas las series que se
    pintan y lee las alertas activas no silenciadas de Gjallarhorn, ambas por la red interna, y
    responde un JSON pequeño. La tablet no habla PromQL ni carga Grafana.
- **Token de solo lectura propio**, `HLIDSKJALF_TOKEN`, distinto del del webhook (T4): quien lo
  tenga ve el estado pero no puede inyectar alertas. Viaja como `Bearer`. Sin token configurado,
  o con uno de menos de 32 caracteres, el resumen responde 503: cerrado, no abierto. La página
  lo recibe una vez en el fragmento de la URL (`#t=`), que el navegador no envía al servidor, y lo
  guarda en `localStorage`.
- **Thor publica servicios y respaldo** (`yggdrasil_servicio_ok`,
  `yggdrasil_respaldo_ultimo_exito_timestamp_seconds`), con el mismo inventario que el vigía. Solo
  se publican: el aviso sigue en el vigía, que no depende de la cadena de alertas.
- **App Android mínima en la tablet** (`hlidskjalf/`): una actividad con un WebView a pantalla
  completa, pantalla siempre encendida, arranque con la tablet y opción de ser la pantalla de
  inicio. Se compila sin Gradle (aapt2, javac, d8, apksigner) y se instala por adb; la URL con el
  token se escribe en los datos privados de la app con `run-as`, por la entrada estándar.
- Nombre: **Hlidskjalf** (Hliðskjálf), el trono de Odín desde el que ve todos los mundos.

## Alternativas consideradas
| Opción | Pros | Contras | Riesgo de seguridad |
|---|---|---|---|
| Página en Nornas + resumen JSON + APK kiosco (elegida) | Sin puertos ni contenedores nuevos; cabe en la tablet; el diseño cambia con un despliegue, sin reinstalar | Nornas suma una ruta pública en la LAN; APK propio que mantener | Token de lectura en la LAN (Interno); APK `debuggable` |
| Odín (Grafana) en modo kiosco | Ya existe; paneles hechos | Grafana 12 no va fluido en Chromium 81 con 1 GB; exige sesión en la tablet | Credencial de Grafana guardada en la tablet |
| App Android nativa que consulte el resumen o MQTT | Más fluida; notificaciones locales | Cada cambio de diseño exige recompilar e instalar; MQTT no tiene el estado del host | Credencial MQTT en la tablet |
| Solo la página, en el navegador Lightning | Nada que instalar | Sin arranque automático ni kiosco; se cierra o navega fuera | Igual que la elegida |
| Publicar Mimir en la LAN | La tablet consultaría directo | Rompe T2 | API de Prometheus alcanzable desde la LAN |

## Consecuencias
- Positivas: estado de midgard visible sin abrir nada; la tablet solo recibe lo que dibuja; el
  tablero dice cuándo sus datos están viejos o una fuente no responde, en vez de quedarse en verde.
- Negativas / deuda asumida: `settings.js` expone dos funciones a los nodos function
  (`consultarJson` con tiempo máximo y `secretoIgual`), no los módulos enteros; el APK es
  `debuggable` para que `run-as` pueda escribir la URL, así que quien tenga adb autorizado en la
  tablet puede leer el token (adb ya permite mucho más en esa ROM `userdebug`); reinstalar exige la
  misma clave de firma, la de depuración del PC que compila; el recolector de Thor tarda unos
  700 ms (antes 300) por los `docker inspect`.
- Impacto en threat model: fila T6 (token del tablero) y nota en T2.
- Impacto en la clasificación de datos: el token es Restringido; lo que muestra el tablero es
  Interno y no sale de la LAN.
- Condiciones de revisión: si la tablet se cambia por un dispositivo con navegador moderno,
  reconsiderar Odín en kiosco; si el tablero se quiere ver fuera de casa, debe ir por WireGuard y
  nunca publicarse en las WAN.
