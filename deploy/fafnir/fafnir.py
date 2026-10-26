#!/usr/bin/env python3
"""Fáfnir: catálogo del almacenamiento de midgard y nidavellir (ADR-0010).

Fáfnir guarda el tesoro y sabe qué hay en él. Inventaría cada ubicación (los recursos del NAS, los
discos de nidavellir, un disco externo cuando está conectado), clasifica lo que encuentra en
colecciones (películas, series, respaldos...) y dice qué está repetido, qué no cumple la política de
copias de su colección y qué solo vive en un disco que falla.

    fafnir.py escanear  --host <host>   inventaría las ubicaciones de ese host y publica el inventario
    fafnir.py catalogar                 junta los inventarios publicados en el catálogo SQLite (midgard)
    fafnir.py informe   [--json]        qué hay, qué se repite y qué está en riesgo
    fafnir.py metricas                  el resumen para Mimir (textfile que sirve Thor)
    fafnir.py mover <origen> <destino> [--borrar-origen]
                                        copia verificando cada fichero por SHA-256; solo con
                                        --borrar-origen, y solo lo verificado, borra el origen

La configuración (/etc/fafnir/fafnir.toml, igual en los dos hosts) va fuera del repositorio: nombra
carpetas personales. Ejemplo comentado en deploy/fafnir/fafnir.ejemplo.toml.

Solo biblioteca estándar (Python >= 3.11: tomllib). No lee el contenido de los ficheros salvo para
la huella: SHA-256 completo en las colecciones con `huella = "completa"` (respaldos) y, en el resto
(vídeo), una huella rápida del tamaño, el primer MiB y el último. La huella se reutiliza mientras el
fichero no cambie de tamaño ni de fecha, así que solo el primer inventario lee mucho.
"""
import argparse
import gzip
import hashlib
import json
import os
import shutil
import socket
import sqlite3
import stat
import sys
import time
import tomllib
from collections import defaultdict
from pathlib import Path

CONFIG = os.environ.get("FAFNIR_CONFIG", "/etc/fafnir/fafnir.toml")
MIB = 1 << 20
BLOQUE = 4 * MIB
# Ficheros que crean los sistemas operativos y no son de nadie
BASURA = {".DS_Store", "Thumbs.db", "desktop.ini", ".localized"}
CARPETAS_SISTEMA = {"$RECYCLE.BIN", "System Volume Information", ".Trash-1000", ".Spotlight-V100",
                    ".fseventsd", ".TemporaryItems", "lost+found"}
TIPOS = {
    "video": "mkv mp4 avi m4v mov wmv ts m2ts mpg mpeg webm flv 3gp mts",
    "subtitulo": "srt sub idx ass ssa vtt",
    "comprimido": "zip rar 7z tar gz tgz bz2 xz iso dmg img",
    "imagen": "jpg jpeg png gif heic bmp tif tiff webp raw cr2 nef psd",
    "audio": "mp3 flac m4a wav aac ogg wma opus",
    "documento": "pdf doc docx xls xlsx ppt pptx txt md odt csv rtf pages numbers key",
    "codigo": "py js ts java c h cpp go rs sh json yml yaml xml html css php sql ipynb",
    "ejecutable": "exe msi apk deb rpm pkg jar dll so bin",
}
TIPO_DE = {e: t for t, es in TIPOS.items() for e in es.split()}


# --- Configuración ----------------------------------------------------------------------------------
def cargar_config(ruta=None):
    with open(ruta or CONFIG, "rb") as f:
        c = tomllib.load(f)
    c.setdefault("ubicacion", [])
    c.setdefault("coleccion", [])
    c.setdefault("medio", [])
    nombres = [u["nombre"] for u in c["ubicacion"]]
    if len(set(nombres)) != len(nombres):
        raise SystemExit("fafnir: hay ubicaciones con el mismo nombre")
    medios = {m["nombre"] for m in c["medio"]}
    for u in c["ubicacion"]:
        for k in ("nombre", "host", "ruta", "medio"):
            if k not in u:
                raise SystemExit(f"fafnir: a la ubicación {u.get('nombre', '?')} le falta `{k}`")
        if u["medio"] not in medios:
            raise SystemExit(f"fafnir: la ubicación {u['nombre']} usa el medio {u['medio']}, que no está declarado")
    for col in c["coleccion"]:
        col.setdefault("copias_minimas", 1)
        col.setdefault("huella", "rapida")
        if col["huella"] not in ("rapida", "completa"):
            raise SystemExit(f"fafnir: huella desconocida en {col['nombre']}: {col['huella']}")
    return c


def coleccion_de(config, ubicacion, ruta):
    """Primera regla `ubicacion:prefijo` que casa; sin regla, `sin-coleccion`."""
    for col in config["coleccion"]:
        for regla in col.get("reglas", []):
            u, _, prefijo = regla.partition(":")
            if u == ubicacion and ruta.startswith(prefijo):
                return col
    return {"nombre": "sin-coleccion", "huella": "rapida", "copias_minimas": 0}


def tipo_de(nombre):
    n = nombre.rsplit("/", 1)[-1]
    if n in BASURA or n.startswith("._"):
        return "basura-sistema"
    if "." not in n:
        return "otros"
    e = n.rsplit(".", 1)[1].lower()
    if e.isdigit() or (len(e) == 3 and e[0] == "r" and e[1:].isdigit()):   # partes .001, .r00
        return "comprimido"
    return TIPO_DE.get(e, "otros")


# --- Huellas ----------------------------------------------------------------------------------------
def huella_completa(ruta):
    h = hashlib.sha256()
    with open(ruta, "rb") as f:
        while bloque := f.read(BLOQUE):
            h.update(bloque)
    return "sha256:" + h.hexdigest()


def huella_rapida(ruta, tamano):
    """Tamaño + primer MiB + último MiB. Para vídeos: distingue ficheros distintos sin leer GB."""
    h = hashlib.sha256(str(tamano).encode())
    with open(ruta, "rb") as f:
        h.update(f.read(MIB))
        if tamano > 2 * MIB:
            f.seek(-MIB, os.SEEK_END)
            h.update(f.read(MIB))
    return "rapida:" + h.hexdigest()


# --- escanear ---------------------------------------------------------------------------------------
def recorrer(raiz, excluir):
    """(ruta relativa, os.stat_result) de cada fichero regular, sin seguir enlaces ni cruzar montajes."""
    raiz = os.path.abspath(raiz)
    dispositivo = os.stat(raiz).st_dev
    pila = [""]
    while pila:
        rel = pila.pop()
        try:
            entradas = list(os.scandir(os.path.join(raiz, rel)))
        except OSError as e:
            print(f"fafnir: no se puede leer {os.path.join(raiz, rel)}: {e.strerror}", file=sys.stderr)
            continue
        for e in entradas:
            r = f"{rel}/{e.name}" if rel else e.name
            if e.name in CARPETAS_SISTEMA or r in excluir:
                continue
            try:
                st = e.stat(follow_symlinks=False)
            except OSError:
                continue
            if stat.S_ISDIR(st.st_mode):
                if st.st_dev == dispositivo:
                    pila.append(r)
            elif stat.S_ISREG(st.st_mode):
                yield r, st


def leer_inventario(ruta):
    """Cabecera y ficheros de un inventario .jsonl.gz; (None, []) si no existe o está roto."""
    try:
        with gzip.open(ruta, "rt", encoding="utf-8") as f:
            lineas = f.read().splitlines()
        return json.loads(lineas[0]), [json.loads(l) for l in lineas[1:]]
    except (OSError, EOFError, ValueError, IndexError):
        return None, []


def escribir_atomico(ruta, contenido, comprimir=False):
    ruta = Path(ruta)
    ruta.parent.mkdir(parents=True, exist_ok=True)
    tmp = ruta.with_name(f".{ruta.name}.{os.getpid()}.tmp")
    datos = contenido.encode("utf-8")
    with open(tmp, "wb") as f:
        f.write(gzip.compress(datos, mtime=0) if comprimir else datos)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, 0o644)
    os.replace(tmp, ruta)


def escanear_ubicacion(config, u, estado, ahora):
    """Inventario de una ubicación, reutilizando la huella de lo que no cambió desde el anterior."""
    propio = Path(estado) / f"{u['nombre']}.jsonl.gz"
    _, previos = leer_inventario(propio)
    cache = {(p["r"], p["t"], p["m"]): p["h"] for p in previos if p.get("h")}
    excluir = set(u.get("excluir", []))
    ficheros, leidos, reutilizados, errores = [], 0, 0, 0
    for rel, st in recorrer(u["ruta"], excluir):
        col = coleccion_de(config, u["nombre"], rel)
        f = {"r": rel, "t": st.st_size, "m": st.st_mtime_ns, "c": col["nombre"], "k": tipo_de(rel)}
        if f["k"] != "basura-sistema" and st.st_size > 0:
            # una huella rápida de la cache no vale si la colección pide la completa
            h = cache.get((rel, st.st_size, st.st_mtime_ns))
            if h and (col["huella"] == "rapida" or h.startswith("sha256:")):
                reutilizados += 1
            else:
                try:
                    absoluta = os.path.join(u["ruta"], rel)
                    h = huella_completa(absoluta) if col["huella"] == "completa" else huella_rapida(absoluta, st.st_size)
                    leidos += 1
                except OSError as e:
                    print(f"fafnir: {u['nombre']}: no se puede leer {rel}: {e.strerror}", file=sys.stderr)
                    h, errores = None, errores + 1
            f["h"] = h
        ficheros.append(f)
        if len(ficheros) % 1000 == 0:
            print(f"  {u['nombre']}: {len(ficheros)} ficheros; huellas leídas {leidos}, reutilizadas {reutilizados}", flush=True)
    cabecera = {"version": 1, "ubicacion": u["nombre"], "host": u["host"], "medio": u["medio"], "ruta": u["ruta"],
                "escaneado": ahora, "ficheros": len(ficheros), "bytes": sum(f["t"] for f in ficheros),
                "errores": errores}
    cuerpo = "\n".join([json.dumps(cabecera, ensure_ascii=False)] + [json.dumps(f, ensure_ascii=False) for f in ficheros]) + "\n"
    escribir_atomico(propio, cuerpo, comprimir=True)
    return cabecera, leidos, reutilizados


def montada(u):
    """Una ubicación `opcional` (un disco externo) puede no estar; las demás tienen que estar."""
    try:
        return os.path.isdir(u["ruta"]) and (not u.get("punto_de_montaje") or os.path.ismount(u["ruta"]))
    except OSError:
        return False


def cmd_escanear(config, args):
    host = args.host or socket.gethostname()
    estado = config.get("estado", "/var/lib/fafnir")
    intercambio = config.get("intercambio")
    ahora = int(time.time())
    propias = [u for u in config["ubicacion"] if u["host"] == host]
    if not propias:
        raise SystemExit(f"fafnir: ninguna ubicación es del host {host}")
    fallos = 0
    for u in propias:
        if not montada(u):
            if u.get("opcional"):
                print(f"{u['nombre']}: no está conectada; se conserva su último inventario")
                continue
            print(f"fafnir: {u['nombre']}: {u['ruta']} no está disponible", file=sys.stderr)
            fallos += 1
            continue
        t0 = time.monotonic()
        cab, leidos, reutilizados = escanear_ubicacion(config, u, estado, ahora)
        print(f"{u['nombre']}: {cab['ficheros']} ficheros, {cab['bytes'] / 1e9:.1f} GB; huellas leídas {leidos}, "
              f"reutilizadas {reutilizados}, errores {cab['errores']} ({time.monotonic() - t0:.0f} s)")
        if intercambio:
            publicar(Path(estado) / f"{u['nombre']}.jsonl.gz", Path(intercambio) / "inventarios" / f"{u['nombre']}.jsonl.gz")
    return 1 if fallos else 0


def publicar(origen, destino):
    """Copia atómica al directorio de intercambio (el NAS): quien lo lee nunca ve uno a medias."""
    destino.parent.mkdir(parents=True, exist_ok=True)
    tmp = destino.with_name(f".{destino.name}.{os.getpid()}.tmp")
    shutil.copyfile(origen, tmp)
    os.replace(tmp, destino)


# --- catalogar --------------------------------------------------------------------------------------
ESQUEMA = """
CREATE TABLE medio (nombre TEXT PRIMARY KEY, descripcion TEXT, riesgo INTEGER NOT NULL);
CREATE TABLE ubicacion (nombre TEXT PRIMARY KEY, host TEXT, medio TEXT REFERENCES medio, ruta TEXT,
                        opcional INTEGER, escaneado INTEGER, ficheros INTEGER, bytes INTEGER, errores INTEGER);
CREATE TABLE coleccion (nombre TEXT PRIMARY KEY, copias_minimas INTEGER, huella TEXT, descripcion TEXT);
CREATE TABLE fichero (ubicacion TEXT REFERENCES ubicacion, ruta TEXT, tamano INTEGER, mtime_ns INTEGER,
                      coleccion TEXT, tipo TEXT, huella TEXT, PRIMARY KEY (ubicacion, ruta));
CREATE INDEX fichero_contenido ON fichero (tamano, huella);
CREATE INDEX fichero_coleccion ON fichero (coleccion);
"""


def cmd_catalogar(config, args):
    intercambio = config.get("intercambio")
    if not intercambio:
        raise SystemExit("fafnir: falta `intercambio` en la configuración")
    destino = Path(config.get("catalogo", "/var/lib/fafnir/catalogo.db"))
    destino.parent.mkdir(parents=True, exist_ok=True)
    tmp = destino.with_name(f".{destino.name}.tmp")
    tmp.unlink(missing_ok=True)
    db = sqlite3.connect(tmp)
    db.executescript(ESQUEMA)
    db.executemany("INSERT INTO medio VALUES (?, ?, ?)",
                   [(m["nombre"], m.get("descripcion", ""), int(bool(m.get("riesgo")))) for m in config["medio"]])
    db.executemany("INSERT INTO coleccion VALUES (?, ?, ?, ?)",
                   [(c["nombre"], c["copias_minimas"], c["huella"], c.get("descripcion", "")) for c in config["coleccion"]]
                   + [("sin-coleccion", 0, "rapida", "lo que ninguna regla clasifica")])
    sin_inventario = []
    for u in config["ubicacion"]:
        cab, ficheros = leer_inventario(Path(intercambio) / "inventarios" / f"{u['nombre']}.jsonl.gz")
        if cab is None:
            sin_inventario.append(u["nombre"])
            cab = {}
        db.execute("INSERT INTO ubicacion VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                   (u["nombre"], u["host"], u["medio"], u["ruta"], int(bool(u.get("opcional"))),
                    cab.get("escaneado"), cab.get("ficheros", 0), cab.get("bytes", 0), cab.get("errores", 0)))
        # La colección se recalcula aquí: cambiar una regla no exige volver a inventariar
        db.executemany("INSERT INTO fichero VALUES (?, ?, ?, ?, ?, ?, ?)",
                       [(u["nombre"], f["r"], f["t"], f["m"], coleccion_de(config, u["nombre"], f["r"])["nombre"],
                         f["k"], f.get("h")) for f in ficheros])
    db.commit()
    db.close()
    os.chmod(tmp, 0o640)
    os.replace(tmp, destino)
    for n in sin_inventario:
        print(f"fafnir: {n}: sin inventario publicado todavía", file=sys.stderr)
    print(f"catálogo: {destino}")
    return 0


# --- informe ----------------------------------------------------------------------------------------
def abrir_catalogo(config):
    ruta = Path(config.get("catalogo", "/var/lib/fafnir/catalogo.db"))
    if not ruta.exists():
        raise SystemExit(f"fafnir: no hay catálogo en {ruta}: ejecutar antes `fafnir.py catalogar`")
    db = sqlite3.connect(f"file:{ruta}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    return db


def analizar(db):
    """Agrega el catálogo por contenido (tamaño + huella) y por medio físico.

    Una copia es un medio distinto: dos carpetas del mismo NAS son una sola copia. Una copia sana
    es la que está en un medio sin `riesgo`.
    """
    medios = {r["nombre"]: dict(r) for r in db.execute("SELECT * FROM medio")}
    ubicaciones = {r["nombre"]: dict(r) for r in db.execute("SELECT * FROM ubicacion")}
    colecciones = {r["nombre"]: dict(r) for r in db.execute("SELECT * FROM coleccion")}
    contenido = defaultdict(lambda: {"tamano": 0, "medios": set(), "colecciones": set(), "rutas": []})
    por_ubicacion = defaultdict(lambda: defaultdict(lambda: [0, 0]))
    for f in db.execute("SELECT f.*, u.medio FROM fichero f JOIN ubicacion u ON u.nombre = f.ubicacion"):
        por_ubicacion[f["ubicacion"]][f["coleccion"]][0] += f["tamano"]
        por_ubicacion[f["ubicacion"]][f["coleccion"]][1] += 1
        if f["tipo"] == "basura-sistema" or not f["huella"] or f["tamano"] == 0:
            continue
        c = contenido[(f["tamano"], f["huella"])]
        c["tamano"] = f["tamano"]
        c["medios"].add(f["medio"])
        c["colecciones"].add(f["coleccion"])
        c["rutas"].append(f"{f['ubicacion']}:{f['ruta']}")
    resumen = {}
    for nombre, col in colecciones.items():
        resumen[nombre] = {"copias_minimas": col["copias_minimas"], "bytes": 0, "contenidos": 0,
                           "bytes_en_riesgo": 0, "bytes_bajo_politica": 0, "bytes_repetidos": 0,
                           "en_riesgo": [], "bajo_politica": []}
    repetidos = defaultdict(lambda: [0, 0])
    for c in contenido.values():
        sanos = {m for m in c["medios"] if not medios.get(m, {}).get("riesgo")}
        # Un contenido en varias colecciones (un respaldo que también está en «personal») cuenta para la más exigente
        col = max(c["colecciones"], key=lambda n: colecciones.get(n, {}).get("copias_minimas", 0))
        r = resumen.setdefault(col, {"copias_minimas": 0, "bytes": 0, "contenidos": 0, "bytes_en_riesgo": 0,
                                     "bytes_bajo_politica": 0, "bytes_repetidos": 0, "en_riesgo": [], "bajo_politica": []})
        r["bytes"] += c["tamano"]
        r["contenidos"] += 1
        if len(c["medios"]) > 1:
            r["bytes_repetidos"] += c["tamano"] * (len(c["medios"]) - 1)
            clave = " + ".join(sorted(c["medios"]))
            repetidos[clave][0] += c["tamano"]
            repetidos[clave][1] += 1
        if not sanos:
            r["bytes_en_riesgo"] += c["tamano"]
            r["en_riesgo"].append((c["tamano"], c["rutas"][0]))
        if len(sanos) < r["copias_minimas"]:
            r["bytes_bajo_politica"] += c["tamano"]
            r["bajo_politica"].append((c["tamano"], c["rutas"][0], len(sanos)))
    for r in resumen.values():
        r["en_riesgo"].sort(reverse=True)
        r["bajo_politica"].sort(reverse=True)
    return {"medios": medios, "ubicaciones": ubicaciones, "colecciones": resumen,
            "por_ubicacion": por_ubicacion, "repetidos": repetidos}


def cmd_informe(config, args):
    a = analizar(abrir_catalogo(config))
    if args.json:
        salida = {
            "ubicaciones": a["ubicaciones"],
            "colecciones": {n: {k: v for k, v in r.items() if k not in ("en_riesgo", "bajo_politica")}
                            | {"en_riesgo": r["en_riesgo"][:50], "bajo_politica": r["bajo_politica"][:50]}
                            for n, r in a["colecciones"].items()},
            "repetidos": {k: {"bytes": v[0], "contenidos": v[1]} for k, v in a["repetidos"].items()},
        }
        print(json.dumps(salida, ensure_ascii=False, indent=1))
        return 0
    gb = lambda b: f"{b / 1e9:9.1f} GB"
    ahora = int(time.time())
    print("UBICACIONES")
    for u in a["ubicaciones"].values():
        riesgo = " (en riesgo)" if a["medios"].get(u["medio"], {}).get("riesgo") else ""
        edad = "sin inventario" if not u["escaneado"] else f"inventario de hace {(ahora - u['escaneado']) // 3600} h"
        print(f"  {u['nombre']:22s} {u['host']:11s} medio {u['medio']}{riesgo:13s} {gb(u['bytes'] or 0)} "
              f"{u['ficheros'] or 0:8d} ficheros · {edad}")
    print("\nCOLECCIONES (por contenido único; copias = medios físicos sanos)")
    for n, r in sorted(a["colecciones"].items(), key=lambda x: -x[1]["bytes"]):
        if not r["contenidos"]:
            continue
        print(f"  {n:22s} {gb(r['bytes'])} {r['contenidos']:7d} ficheros · pide {r['copias_minimas']} copia(s) · "
              f"repetido {gb(r['bytes_repetidos']).strip()} · bajo política {gb(r['bytes_bajo_politica']).strip()} · "
              f"en riesgo {gb(r['bytes_en_riesgo']).strip()}")
    print("\nDÓNDE ESTÁ CADA COLECCIÓN")
    for u, cols in a["por_ubicacion"].items():
        for col, (b, nf) in sorted(cols.items(), key=lambda x: -x[1][0]):
            if b >= 1e8:
                print(f"  {u:22s} {col:22s} {gb(b)} {nf:7d} ficheros")
    print("\nREPETIDO ENTRE MEDIOS")
    for k, (b, nf) in sorted(a["repetidos"].items(), key=lambda x: -x[1][0]):
        print(f"  {gb(b)} {nf:7d} contenidos  {k}")
    for etiqueta, clave in (("SOLO EN MEDIOS EN RIESGO", "en_riesgo"), ("POR DEBAJO DE SU POLÍTICA DE COPIAS", "bajo_politica")):
        filas = [(n, x) for n, r in a["colecciones"].items() for x in r[clave]]
        if not filas:
            continue
        print(f"\n{etiqueta} (los 15 más grandes)")
        for n, x in sorted(filas, key=lambda f: -f[1][0])[:15]:
            print(f"  {gb(x[0])}  {n:20s} {x[1]}")
    return 0


# --- metricas ---------------------------------------------------------------------------------------
def etiqueta(v):
    return str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def cmd_metricas(config, args):
    a = analizar(abrir_catalogo(config))
    lineas = [
        "# HELP fafnir_catalogo_timestamp_seconds Cuándo se generó esta salida de Fáfnir.",
        "# TYPE fafnir_catalogo_timestamp_seconds gauge",
        f"fafnir_catalogo_timestamp_seconds {int(time.time())}",
        "# HELP fafnir_inventario_timestamp_seconds Último inventario de cada ubicación.",
        "# TYPE fafnir_inventario_timestamp_seconds gauge",
    ]
    for u in a["ubicaciones"].values():
        # Una ubicación fija que nunca se inventarió sale con 0: FafnirInventarioViejo la ve. Una opcional
        # (un disco externo) sin inventario no sale: no conectarla no es un fallo.
        if u["escaneado"] or not u["opcional"]:
            lineas.append(f'fafnir_inventario_timestamp_seconds{{ubicacion="{etiqueta(u["nombre"])}",host="{etiqueta(u["host"])}",'
                          f'opcional="{u["opcional"]}"}} {u["escaneado"] or 0}')
    lineas += ["# HELP fafnir_ubicacion_bytes Bytes de cada colección en cada ubicación.",
               "# TYPE fafnir_ubicacion_bytes gauge"]
    for u, cols in a["por_ubicacion"].items():
        medio = a["ubicaciones"].get(u, {}).get("medio", "")
        for col, (b, _) in cols.items():
            lineas.append(f'fafnir_ubicacion_bytes{{ubicacion="{etiqueta(u)}",medio="{etiqueta(medio)}",coleccion="{etiqueta(col)}"}} {b}')
    for nombre, ayuda, clave in (
            ("fafnir_coleccion_bytes", "Bytes de contenido único de cada colección.", "bytes"),
            ("fafnir_coleccion_repetidos_bytes", "Bytes de copias de más (en más de un medio).", "bytes_repetidos"),
            ("fafnir_coleccion_bajo_politica_bytes", "Bytes con menos copias sanas de las que pide la colección.", "bytes_bajo_politica"),
            ("fafnir_coleccion_en_riesgo_bytes", "Bytes que solo están en medios en riesgo.", "bytes_en_riesgo")):
        lineas += [f"# HELP {nombre} {ayuda}", f"# TYPE {nombre} gauge"]
        for n, r in a["colecciones"].items():
            lineas.append(f'{nombre}{{coleccion="{etiqueta(n)}",copias_minimas="{r["copias_minimas"]}"}} {r[clave]}')
    destino = config.get("metricas", "/var/lib/yggdrasil-thor/fafnir.prom")
    escribir_atomico(destino, "\n".join(lineas) + "\n")
    print(f"métricas: {destino}")
    return 0


# --- mover ------------------------------------------------------------------------------------------
def copiar_verificando(origen, destino):
    """Copia y devuelve el SHA-256 del origen; relee el destino y falla si no coincide."""
    tmp = destino.with_name(f".{destino.name}.fafnir-tmp")
    h = hashlib.sha256()
    with open(origen, "rb") as fo, open(tmp, "wb") as fd:
        while bloque := fo.read(BLOQUE):
            h.update(bloque)
            fd.write(bloque)
        fd.flush()
        os.fsync(fd.fileno())
    st = os.stat(origen)
    os.utime(tmp, ns=(st.st_atime_ns, st.st_mtime_ns))
    if huella_completa(tmp) != "sha256:" + h.hexdigest():
        tmp.unlink(missing_ok=True)
        raise OSError(f"la copia de {origen} no coincide con el original")
    os.replace(tmp, destino)
    return "sha256:" + h.hexdigest()


def cmd_mover(config, args):
    origen, destino = Path(args.origen).resolve(), Path(args.destino).resolve()
    if not origen.is_dir():
        raise SystemExit(f"fafnir: {origen} no es un directorio")
    if destino == origen or destino.is_relative_to(origen) or origen.is_relative_to(destino):
        raise SystemExit("fafnir: origen y destino no pueden contenerse")
    registro = Path(config.get("estado", "/var/lib/fafnir")) / "movimientos"
    registro.mkdir(parents=True, exist_ok=True)
    # Nanosegundos y modo "x": dos movimientos en el mismo segundo no se pisan el diario
    diario = registro / f"{time.strftime('%Y%m%dT%H%M%S')}-{time.time_ns() % 10**9:09d}.jsonl"
    verificados, fallos, bytes_copiados, saltados = [], 0, 0, 0
    t0 = time.monotonic()
    with open(diario, "x", encoding="utf-8") as d:
        d.write(json.dumps({"origen": str(origen), "destino": str(destino), "borrar_origen": args.borrar_origen}) + "\n")
        for rel, st in recorrer(origen, set()):
            fo, fd = origen / rel, destino / rel
            fd.parent.mkdir(parents=True, exist_ok=True)
            try:
                if fd.exists() and fd.stat().st_size == st.st_size and huella_completa(fd) == huella_completa(fo):
                    h, saltados = None, saltados + 1   # ya estaba: verificado igual
                else:
                    h = copiar_verificando(fo, fd)
                    bytes_copiados += st.st_size
                verificados.append(rel)
                d.write(json.dumps({"r": rel, "t": st.st_size, "h": h, "ok": True}, ensure_ascii=False) + "\n")
            except OSError as e:
                fallos += 1
                print(f"fafnir: {rel}: {e}", file=sys.stderr)
                d.write(json.dumps({"r": rel, "t": st.st_size, "ok": False, "error": str(e)}, ensure_ascii=False) + "\n")
            if len(verificados) % 100 == 0 and verificados:
                print(f"  {len(verificados)} verificados, {bytes_copiados / 1e9:.1f} GB copiados", flush=True)
        borrados = 0
        if args.borrar_origen:
            if fallos:
                print(f"fafnir: {fallos} fallos: no se borra nada del origen", file=sys.stderr)
            else:
                for rel in verificados:
                    (origen / rel).unlink()
                    borrados += 1
                for raiz, dirs, ficheros in os.walk(origen, topdown=False):
                    if raiz != str(origen) and not os.listdir(raiz):
                        os.rmdir(raiz)
                d.write(json.dumps({"borrados": borrados}) + "\n")
    print(f"mover: {len(verificados)} verificados ({saltados} ya estaban), {bytes_copiados / 1e9:.1f} GB copiados, "
          f"{fallos} fallos, {borrados} borrados del origen, {time.monotonic() - t0:.0f} s; diario {diario}")
    return 1 if fallos else 0


def main(argv=None):
    p = argparse.ArgumentParser(prog="fafnir", description=__doc__.split("\n\n")[0])
    p.add_argument("--config", default=None)
    sub = p.add_subparsers(dest="orden", required=True)
    e = sub.add_parser("escanear")
    e.add_argument("--host", default=os.environ.get("FAFNIR_HOST"))
    sub.add_parser("catalogar")
    i = sub.add_parser("informe")
    i.add_argument("--json", action="store_true")
    sub.add_parser("metricas")
    m = sub.add_parser("mover")
    m.add_argument("origen")
    m.add_argument("destino")
    m.add_argument("--borrar-origen", action="store_true")
    args = p.parse_args(argv)
    config = cargar_config(args.config)
    return {"escanear": cmd_escanear, "catalogar": cmd_catalogar, "informe": cmd_informe,
            "metricas": cmd_metricas, "mover": cmd_mover}[args.orden](config, args)


if __name__ == "__main__":
    sys.exit(main())
