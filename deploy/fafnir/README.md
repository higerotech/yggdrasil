# Fáfnir: catálogo del almacenamiento

Fáfnir guarda el tesoro y sabe qué hay en él (ADR-0010). Inventaría el NAS, los discos de nidavellir y los
discos externos que se conecten a midgard. Junta todo en un catálogo y responde a tres preguntas:

- qué ocupa cada colección y dónde;
- qué está repetido;
- qué tiene menos copias de las que pide su colección, o solo vive en un disco que falla.

## Cómo funciona

```
nidavellir  fafnir-escaneo.timer (03:30) ─┐
midgard     fafnir-escaneo.timer (03:30) ─┼─> NAS: descargas/fafnir/inventarios/<ubicación>.jsonl.gz
                                          │
midgard     fafnir-catalogo.timer (06:00) ─> /var/lib/fafnir/catalogo.db  +  /var/lib/yggdrasil-thor/fafnir.prom
                                                                              └─> Thor ─> Mimir (job fafnir)
```

| Concepto | Qué es |
|---|---|
| **medio** | un soporte físico: `nas`, `wd`, `samsung`, `toshiba`. Con `riesgo = true`, lo que solo esté ahí sale «en riesgo» |
| **ubicación** | una raíz de un medio, vista desde un host: `nas-media` es `/mnt/nas/media` en midgard |
| **colección** | `peliculas`, `series`, `respaldos-servicios`, `personal`. Reglas `ubicación:prefijo` y `copias_minimas` |
| **contenido** | tamaño + huella. La misma película en el NAS y en el WD es un contenido con dos copias |

**Huellas:**
- `huella = "completa"`: SHA-256 entero, para los respaldos.
- `"rapida"`: el tamaño, el primer MiB y el último, para los vídeos.

La huella se reutiliza mientras el fichero no cambie de tamaño ni de fecha.

## Instalación

En midgard lo instala `bootstrap-midgard.sh` (paso 5h). En nidavellir, a mano:

```sh
sudo install -d -m 0755 /usr/local/lib/fafnir
sudo install -m 0755 deploy/fafnir/fafnir.py /usr/local/lib/fafnir/
sudo install -m 0644 deploy/fafnir/fafnir-escaneo.service deploy/fafnir/fafnir-escaneo.timer /etc/systemd/system/
echo "FAFNIR_HOST=nidavellir" | sudo tee /etc/default/fafnir
```

Después, en los dos hosts:
1. Copiar `/etc/fafnir/fafnir.toml`, partiendo de `fafnir.ejemplo.toml`. Tiene que ser **igual en los dos**.
2. `sudo systemctl daemon-reload && sudo systemctl enable --now fafnir-escaneo.timer`.
3. Solo en midgard, además, `fafnir-catalogo.timer`.

## Uso

```sh
sudo systemctl start fafnir-escaneo        # inventario ahora (el primero lee la huella de todo)
sudo systemctl start fafnir-catalogo       # catálogo y métricas (midgard)
sudo python3 /usr/local/lib/fafnir/fafnir.py informe          # o --json
sudo python3 /usr/local/lib/fafnir/fafnir.py mover /mnt/nas/media/movies /srv/medios/wd/peliculas
sudo python3 /usr/local/lib/fafnir/fafnir.py mover /mnt/nas/media/movies /srv/medios/wd/peliculas --borrar-origen
```

**`mover`:**
- Copia cada fichero, relee la copia y compara su SHA-256 con el del origen. Conserva la fecha.
- Lo que ya está en el destino, idéntico, no se vuelve a copiar.
- Con `--borrar-origen`, y solo si no hubo ningún fallo, borra del origen lo verificado.
- Deja un diario por movimiento en `/var/lib/fafnir/movimientos/`.

## Métricas y alertas

| Métrica | Qué es |
|---|---|
| `fafnir_ubicacion_bytes{ubicacion,medio,coleccion}` | bytes de cada colección en cada ubicación |
| `fafnir_coleccion_bytes{coleccion,copias_minimas}` | contenido único de la colección |
| `fafnir_coleccion_repetidos_bytes` | copias de más: el mismo contenido en otro medio |
| `fafnir_coleccion_bajo_politica_bytes` | contenido con menos copias sanas de las que pide la colección |
| `fafnir_coleccion_en_riesgo_bytes` | contenido que solo está en medios en riesgo |
| `fafnir_inventario_timestamp_seconds{ubicacion,host,opcional}` | último inventario de cada ubicación |
| `fafnir_catalogo_timestamp_seconds` | cuándo se generó el catálogo |

**Alertas** (`prometheus/rules/fafnir-alertas.yml`):
- `FafnirDatosEnRiesgo`: hay datos que solo están en discos que fallan.
- `FafnirColeccionSinCopias`: faltan copias, sin repetir el aviso de riesgo.
- `FafnirInventarioViejo`: una ubicación fija lleva más de 2 días sin inventario.
- `FafnirSinCatalogo`: no se ha generado el catálogo.

## Pruebas

`python3 -m unittest discover -s deploy/fafnir/tests -v`, sobre árboles de ficheros temporales. Cubre:
- inventario, exclusiones y papeleras;
- huellas y su reutilización;
- copias por medio, riesgo y política;
- informe y métricas;
- `mover`, incluida una copia que no coincide;
- la configuración de ejemplo.

Las alertas: `promtool test rules deploy/prometheus/tests/fafnir-alertas.test.yml`.
