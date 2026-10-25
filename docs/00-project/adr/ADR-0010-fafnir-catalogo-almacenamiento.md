# ADR-0010: Fáfnir, catálogo del almacenamiento de midgard y nidavellir

* **Estado:** accepted
* **Fecha:** 2026-10-25
* **Decisores:** Jeremi
* **Fase AI-DLC:** 02-design
* **Versión:** 1.0.0
* **ID:** ADR-0010
* **Supersede / Superseded-by:** —
* **Controles OWASP afectados:** A01 (el catálogo y los inventarios son de root; la configuración, que nombra carpetas personales, no va al repositorio), A04 (mover solo borra el origen con `--borrar-origen` y tras verificar cada copia por SHA-256), A05 (sin puertos ni contenedores nuevos), A09 (métricas y alertas en Heimdall)

## Contexto
El NAS (3,6 TB) está al 96–99 % y los respaldos de los servicios compiten por su espacio con la biblioteca
de Bragi. El 2026-10-25 se inventariaron, en solo lectura, el NAS y los discos de nidavellir:

| Ubicación | Tamaño | Contenido |
|---|---|---|
| NAS · `media` | 3095 GB | series 2391 GB (43), películas 705 GB (171) |
| NAS · `respaldos` | 19 GB | respaldos de los servicios |
| NAS · fuera de lo montado | ~335 GB | sin identificar desde midgard |
| nidavellir · Samsung HD154UI 1,5 TB | 1190 GB | 167 de las 171 películas del NAS, más `Projects` (56 GB) que solo está ahí; **sectores ilegibles** |
| nidavellir · WD10EZEX 1 TB | 222 GB | respaldos personales; un sector ilegible, se reformatea |
| midgard · Toshiba externo 1 TB (USB) | 554 GB | respaldos personales; 11 840 sectores reasignados y 2880 pendientes |

Nadie sabía qué estaba repetido, qué solo vivía en un disco que falla ni qué se podía mover. Los
respaldos personales no tenían ninguna copia en el NAS. Jeremi quiere sacar películas (y parte de las
series) del NAS para dejarle sitio a los respaldos importantes.

## Decisión
- **Fáfnir**, un único script de Python sin dependencias (`deploy/fafnir/fafnir.py`, Python ≥ 3.11), con
  cinco órdenes: `escanear`, `catalogar`, `informe`, `metricas` y `mover`.
- **Modelo:**
  - un **medio** es un soporte físico (el NAS, el WD, el Samsung, el Toshiba), y puede estar marcado `riesgo`;
  - una **ubicación** es una raíz de un medio vista desde un host;
  - una **colección** (películas, series, respaldos de servicios, personal) agrupa ficheros por reglas
    `ubicación:prefijo` y fija sus `copias_minimas`.
- **Las copias se cuentan por medio sano y por contenido** (tamaño + huella), no por carpeta ni por nombre:
  dos carpetas del NAS son una copia, y una película renombrada sigue siendo la misma.
- **Huella:**
  - SHA-256 completo en las colecciones que lo piden (respaldos);
  - en el resto (vídeo), una huella rápida del tamaño, el primer MiB y el último;
  - se reutiliza mientras el fichero no cambia de tamaño ni de fecha, así que solo el primer inventario lee mucho.
- **Cada host inventaría lo suyo** (`fafnir-escaneo.timer`, 03:30, disco en clase idle) y publica el
  inventario en el NAS (`descargas/fafnir/inventarios/`; no en `respaldos`, para que ese recurso pueda volver a ser
  solo de midgard). **midgard junta todo** en un SQLite
  (`fafnir-catalogo.timer`, 06:00) y escribe `fafnir.prom` en el directorio que sirve Thor. Mimir lo recoge
  en el job `fafnir`. Sin puertos nuevos: el NAS ya lo montan los dos hosts.
- **La configuración** (`/etc/fafnir/fafnir.toml`) es igual en los dos hosts y va fuera del repositorio: nombra
  carpetas personales. En el repositorio hay un ejemplo (`fafnir.ejemplo.toml`) que las pruebas cargan.
- **`mover` copia verificando:** relee cada copia y compara su SHA-256 con el del origen, y conserva la fecha.
  Solo con `--borrar-origen`, y solo si no hubo ningún fallo, borra el origen. Deja un diario JSONL por
  movimiento.
- **Alertas** (`fafnir-alertas.yml`):
  - `FafnirDatosEnRiesgo`: hay datos que solo están en medios en riesgo;
  - `FafnirColeccionSinCopias`: una colección tiene menos copias sanas de las que pide, sin repetir el aviso
    de riesgo;
  - `FafnirInventarioViejo`: una ubicación fija lleva más de 2 días sin inventario;
  - `FafnirSinCatalogo`.
- **Primera organización** (decisión de Jeremi, 2026-10-25):
  - las películas pasan del NAS al WD de nidavellir (`/srv/medios/wd/peliculas`), verificadas, y se
    borran del NAS: libera 705 GB;
  - `Projects` sale del Samsung;
  - los respaldos personales se ordenan, sin duplicados, en `respaldos/personal` del NAS.

## Alternativas consideradas
| Opción | Pros | Contras | Riesgo de seguridad |
|---|---|---|---|
| Fáfnir: script propio, inventario por host y catálogo SQLite (elegida) | Sin dependencias ni servicios nuevos; entiende medios en riesgo y políticas de copias; métricas en Heimdall | Código propio que mantener | Lista de ficheros personales en el NAS (que ya tiene el contenido) |
| `fdupes`/`rmlint` puntual | Encuentra duplicados ya | Una foto del momento, sin política, sin histórico ni alertas; no ve entre hosts | Ninguno nuevo |
| git-annex | Sabe dónde está cada copia y las mueve con verificación | Cambia cómo se guardan los ficheros (enlaces simbólicos); mal encaje con Jellyfin y el NAS | Ninguno nuevo |
| Un indexador con interfaz (diskover, Elasticsearch) | Búsqueda y paneles hechos | Servicio pesado y una base más en el HDD de midgard, para pocos cientos de miles de ficheros | Otro puerto y otra credencial |

## Consecuencias
- Positivas:
  - qué hay, dónde y cuántas copias tiene se responde con una orden, y Mimir avisa cuando algo queda en riesgo;
  - los movimientos dejan diario y nunca borran sin verificar.
- Negativas / deuda asumida:
  - el primer inventario de los respaldos lee entero cada fichero (SHA-256);
  - `riesgo` es manual, en la configuración. Podría derivarse del SMART de Thor
    (`yggdrasil_smart_atributo` 197/198 > 0), y queda como mejora;
  - los ~335 GB del NAS fuera de lo montado no se ven hasta montar ese recurso;
  - sin panel en Odín ni en Hlidskjalf todavía, solo `informe` y alertas.
- Impacto en el threat model: nota en T2. No hay puerto nuevo: los inventarios viajan por el NAS, que ya
  exporta sus recursos a toda la LAN, así que la lista de nombres no expone más que el contenido que ya es
  accesible.
- Impacto en la clasificación de datos: los inventarios y el catálogo son **Interno** (nombres de ficheros
  personales, tamaños y fechas); la configuración también.
- Condiciones de revisión:
  - si el NAS deja de estar abierto a toda la LAN, mover el intercambio a una carpeta con acceso solo para los hosts;
  - si los ficheros pasan del millón, medir el SQLite y el tiempo del inventario.
