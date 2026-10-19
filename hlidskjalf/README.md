# Hlidskjalf — tablero de pared de midgard

Hlidskjalf (Hliðskjálf) es el trono desde el que Odín ve todos los mundos: aquí, una tablet fija en
la pared que enseña de un vistazo el estado de midgard. Decisión y alternativas en
[ADR-0007](../docs/00-project/adr/ADR-0007-hlidskjalf-tablero-pared.md).

```
tablet (WebView) ──GET /hlidskjalf/──────────▶ Nornas :1880 ─┬─▶ Mimir       (una consulta instantánea)
                 ──GET /hlidskjalf/resumen───▶  (Bearer)     └─▶ Gjallarhorn (alertas activas)
                                                                   ▲
                                         Thor (host) ── servicios, respaldo, disco, NAS, ruta
```

| Bloque | Qué enseña | Fuente |
|---|---|---|
| WAN | en línea o caída, si está en la ruta del balanceador, latencia p95, pérdida, última medición de bajada y subida frente al SLO, disponibilidad de 30 días. Caída, en vez de latencia y velocidades, desde cuándo (la hora de su `WanCaida`) | `wan:*`, Sleipnir, Thor, Alertmanager |
| Respaldos | una línea bajo las WAN con la edad de cada respaldo, en ámbar si pasa de 26 h | Thor |
| Alertas activas | las de Gjallarhorn sin silenciar ni inhibir, de la más grave a la más leve; tres como mucho y una línea que nombra las demás. Tiene prioridad sobre Host | Alertmanager |
| Host | SMART de cada disco (solo los contadores que no están a cero) y espacio de `/`, del SSD y del NAS; en el título, si los datos de Thor son viejos | Thor |
| Servicios | contenedores permanentes del Compose; las unidades del host solo con nombre si fallan, las demás en una ficha resumen | Thor (inventario del vigía) |

La cabecera resume el peor estado. Si la tablet pierde la conexión, la cabecera pasa a rojo y, al
minuto, los datos se atenúan: nunca enseña en verde algo que no sabe. También avisa de la batería de
la tablet si no carga, si baja con el cable puesto (el USB de un PC no le da corriente suficiente) o
si queda por debajo del 20 %.

Nada se pierde sin avisar. Si Host no cabe en el alto que le dejan las alertas, el navegador lo
aprieta por pasos: primero junta los discos y volúmenes sanos en una fila «En orden» con su cifra,
luego deja en ella solo los nombres, después pasa las alertas a una línea sin resumen. Si ni así
cabe, un pie nombra las filas tapadas con el color de la peor. Las tarjetas de las WAN se aprietan
igual si la columna izquierda no da para Respaldos.

## Piezas

- `deploy/nornas/hlidskjalf/`: la página (`index.html`, `tablero.css`, `tablero.js`). La compila en
  el flujo `deploy/nornas/generar-flujo.py`, con la CSP por hash. Pruebas en
  `deploy/nornas/tests/hlidskjalf.test.mjs`.
- `deploy/nornas/src/hlidskjalf-*.js`: autorización y resumen (nodos function de Nornas).
- `hlidskjalf/app/`: la app Android (una actividad con WebView, `minSdk` 25).
- `hlidskjalf/construir.sh` y `hlidskjalf/instalar.sh`.
- `hlidskjalf/vista-previa.py`, `hlidskjalf/vista-previa.sh` y `hlidskjalf/escenarios/`: probar el diseño
  en la tablet real con escenarios fijos (ver abajo).

## Tablet

Samsung Galaxy Tab 2 10.1 3G (GT-P5100, `espresso3g`), LineageOS 14.1 no oficial (Android 7.1.2,
API 25), 1280×800 a 160 dpi, WebView Chromium 81, sin servicios de Google. Llega a midgard por la
Wi-Fi de casa. **Necesita su cargador de pared** (5 V / 2 A): con un puerto USB de PC se descarga
aunque esté enchufada.

El WebView es Chromium 81: nada de `gap` en flexbox (llegó en la 84), ni sintaxis o APIs
posteriores a 2020. `tablero.js` es ES2017 sin dependencias.

## Compilar

Hace falta un JDK 17 y el SDK de Android con `platforms;android-25` y `build-tools;34.0.0`:

```sh
sdkmanager --sdk_root="$ANDROID_HOME" "platforms;android-25" "build-tools;34.0.0"
ANDROID_HOME=<sdk> bash hlidskjalf/construir.sh          # → hlidskjalf/build/hlidskjalf.apk
```

En Windows, `ANDROID_HOME` sin espacios (sirve la ruta corta 8.3 del perfil, `C:/Users/XXXXXX~1/...`): los `.bat`
del SDK se rompen con espacios. Se firma con la clave de depuración de `~/.android/debug.keystore`;
reinstalar encima exige la misma clave, así que conviene compilar siempre en el mismo PC. El CI
compila con una clave efímera, solo para comprobar que compila.

## Instalar

Con la tablet conectada por USB y la depuración autorizada. La URL lleva el token de solo lectura,
que nace y vive en el `.env` de midgard; esta orden lo lleva de midgard a la tablet por tuberías,
sin imprimirlo ni ponerlo en la línea de órdenes de ningún proceso:

```sh
ssh jalcala@midgard \
    "sudo sed -n 's/^HLIDSKJALF_TOKEN=//p' /srv/apps/yggdrasil/deploy/.env" \
  | sed 's|^|http://<IP LAN de midgard>:1880/hlidskjalf/#t=|' \
  | bash hlidskjalf/instalar.sh --inicio
```

- `--inicio` hace de Hlidskjalf la pantalla de inicio: el botón de inicio y el encendido vuelven al
  tablero. Sin él, la app se abre igual al arrancar la tablet.
- Para actualizar solo el APK y conservar la URL: `bash hlidskjalf/instalar.sh </dev/null`.
- **Salir del kiosco**: cinco toques seguidos en la esquina superior izquierda abren los Ajustes.
  Desde ahí, *Aplicaciones → Pantalla de inicio* devuelve el lanzador de siempre.

Si midgard no tiene aún el token (instalaciones anteriores a la 0.5.9), se crea dentro de midgard,
sin que pase por la pantalla ni por argumentos, y se recrea Nornas:

```sh
sudo -u deploy sh -c 'cd /srv/apps/yggdrasil/deploy &&
  grep -q "^HLIDSKJALF_TOKEN=." .env || { T=$(openssl rand -hex 32) awk "BEGIN{print \"HLIDSKJALF_TOKEN=\" ENVIRON[\"T\"]}" >> .env; }'
```

(`bootstrap-midgard.sh` lo hace solo en instalaciones nuevas: genera cualquier `*_TOKEN` que falte.)

## Probar sin tocar midgard

`adb reverse tcp:1880 tcp:1880` hace que el `127.0.0.1:1880` de la tablet llegue al PC. Con un
Node-RED local que importe el flujo (`deploy/nornas/init/importar-flujo.mjs`) y túneles SSH a Mimir
y Gjallarhorn (`HLIDSKJALF_MIMIR_URL`, `HLIDSKJALF_GJALLARHORN_URL`), la tablet enseña datos reales
servidos por la versión en desarrollo.

## Probar el diseño en la tablet

Para un cambio de la página (`deploy/nornas/hlidskjalf/`), sin Node-RED ni desplegar. `vista-previa.py`
sirve la página tal como está en disco, con la CSP del flujo, y un escenario fijo como resumen. La
página lleva además un medidor: a los 4 s informa de cada fila que queda recortada, tapada o fuera
de la pantalla. La tablet llega al PC por `adb reverse`.

```sh
python3 hlidskjalf/vista-previa.py                       # en otra terminal; puerto 8099
bash hlidskjalf/vista-previa.sh abrir                    # guarda la URL de producción y pasa a la vista previa
bash hlidskjalf/vista-previa.sh probar hlidskjalf/escenarios/estres.json
bash hlidskjalf/vista-previa.sh cerrar                   # restaura la URL (la compara por SHA-256)
```

`probar` recarga la tablet con el escenario y guarda la captura en `hlidskjalf/build/vista-previa/`.
Imprime el alto de cada panel y lo que no se ve entero, y **sale con 1 si se pierde algo**.
`abrir` copia `files/url`, que lleva el token, a `files/url.orig` con `run-as`, sin imprimirla.
`cerrar` la devuelve. Sin `cerrar`, la tablet se queda en la vista previa.

| Escenario | Qué tiene |
|---|---|
| `normal.json` | todo en orden |
| `wan2-caida.json` | el resumen real del 2026-10-19, con wan2 caída |
| `estres.json` | cinco alertas, errores del SSD, NAS al 2,8 %, Bifröst con 31 h, Thor sin datos y cinco servicios caídos. Con este escenario la 0.5.12 perdía cuatro filas de Host |
| `extremo.json` | `estres.json` con once servicios caídos (cuatro filas de fichas) |

Las alertas conservan su antigüedad: el servidor desplaza su `desde` lo mismo que `generado` hasta
la hora actual. Para un escenario con datos de hoy, el resumen de midgard se guarda en `build/`, con el
token dentro del contenedor:

```sh
ssh jalcala@midgard 'docker exec yggdrasil-node-red sh -c "wget -qO- --header \"Authorization: Bearer \$HLIDSKJALF_TOKEN\" http://127.0.0.1:1880/hlidskjalf/resumen"' \
  > hlidskjalf/build/vista-previa/hoy.json
```

El medidor también funciona en Chrome de escritorio, pero la ventana sin interfaz da otro alto útil (1264×705
con `--window-size=1280,800`). El tamaño que cuenta es el de la tablet.
