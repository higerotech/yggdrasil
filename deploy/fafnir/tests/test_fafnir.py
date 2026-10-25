"""Pruebas de Fáfnir (deploy/fafnir/fafnir.py) sobre árboles de ficheros temporales.

    python3 -m unittest discover -s deploy/fafnir/tests -v
"""
import gzip
import json
import os
import sqlite3
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import fafnir  # noqa: E402

MIB = 1 << 20


def escribir(ruta, datos):
    ruta.parent.mkdir(parents=True, exist_ok=True)
    ruta.write_bytes(datos)
    return ruta


class Base(unittest.TestCase):
    """Dos hosts: midgard ve el NAS y un disco externo opcional; nidavellir, el WD y el Samsung (en riesgo)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.t = Path(self.tmp.name)
        t = self.t
        self.pelicula = os.urandom(3 * MIB)
        escribir(t / "nas/movies/Pelicula (2020)/pelicula.mkv", self.pelicula)
        escribir(t / "nas/TV/Serie/S01E01.mkv", os.urandom(MIB))
        escribir(t / "nas/respaldos/yggdrasil/r.tar.gz", b"respaldo de servicio")
        escribir(t / "nas/respaldos/temporal/no-cuenta.bin", b"x" * 100)
        escribir(t / "nas/.DS_Store", b"basura")
        escribir(t / "nas/$RECYCLE.BIN/borrado.mkv", b"papelera")
        escribir(t / "wd/peliculas/Pelicula (2020)/pelicula.mkv", self.pelicula)
        escribir(t / "wd/personal/doc.pdf", b"solo en el WD")
        escribir(t / "samsung/movies/pelicula.mkv", self.pelicula)
        escribir(t / "samsung/Projects/proyecto.py", b"print('solo en el disco que falla')")
        (t / "estado-midgard").mkdir()
        (t / "estado-nidavellir").mkdir()
        self.config = t / "fafnir.toml"
        self.config.write_text(f"""
estado = "{(t / 'estado').as_posix()}"
intercambio = "{(t / 'intercambio').as_posix()}"
catalogo = "{(t / 'catalogo.db').as_posix()}"
metricas = "{(t / 'thor/fafnir.prom').as_posix()}"

[[medio]]
nombre = "nas"
[[medio]]
nombre = "wd"
[[medio]]
nombre = "samsung"
riesgo = true
[[medio]]
nombre = "toshiba"
riesgo = true

[[ubicacion]]
nombre = "nas-media"
host = "midgard"
medio = "nas"
ruta = "{(t / 'nas').as_posix()}"
excluir = ["respaldos/temporal"]
[[ubicacion]]
nombre = "wd-medios"
host = "nidavellir"
medio = "wd"
ruta = "{(t / 'wd').as_posix()}"
[[ubicacion]]
nombre = "samsung"
host = "nidavellir"
medio = "samsung"
ruta = "{(t / 'samsung').as_posix()}"
[[ubicacion]]
nombre = "externo"
host = "midgard"
medio = "toshiba"
ruta = "{(t / 'no-conectado').as_posix()}"
opcional = true
punto_de_montaje = true

[[coleccion]]
nombre = "personal"
copias_minimas = 2
huella = "completa"
reglas = ["wd-medios:personal/", "samsung:Projects/", "nas-media:respaldos/"]
[[coleccion]]
nombre = "peliculas"
reglas = ["nas-media:movies/", "wd-medios:peliculas/", "samsung:movies/"]
[[coleccion]]
nombre = "series"
reglas = ["nas-media:TV/"]
""", encoding="utf-8")

    def tearDown(self):
        self.tmp.cleanup()

    def fafnir(self, *args):
        out, err = StringIO(), StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            rc = fafnir.main(["--config", str(self.config), *args])
        return rc, out.getvalue(), err.getvalue()

    def todo(self):
        for host in ("midgard", "nidavellir"):
            self.assertEqual(self.fafnir("escanear", "--host", host)[0], 0)
        self.assertEqual(self.fafnir("catalogar")[0], 0)

    def inventario(self, nombre):
        return fafnir.leer_inventario(self.t / "intercambio/inventarios" / f"{nombre}.jsonl.gz")


class PruebasEscanear(Base):
    def test_publica_un_inventario_por_ubicacion_del_host(self):
        rc, out, _ = self.fafnir("escanear", "--host", "midgard")
        self.assertEqual(rc, 0)
        cab, ficheros = self.inventario("nas-media")
        self.assertEqual((cab["ubicacion"], cab["host"], cab["medio"]), ("nas-media", "midgard", "nas"))
        rutas = {f["r"]: f for f in ficheros}
        self.assertIn("movies/Pelicula (2020)/pelicula.mkv", rutas)
        self.assertNotIn("respaldos/temporal/no-cuenta.bin", rutas, "excluir")
        self.assertFalse(any("RECYCLE" in r for r in rutas), "papelera de Windows fuera")
        self.assertIsNone(self.inventario("wd-medios")[0], "lo de nidavellir no lo inventaría midgard")
        self.assertIn("externo: no está conectada", out)

    def test_huella_rapida_en_video_y_completa_en_lo_que_la_pide(self):
        self.fafnir("escanear", "--host", "midgard")
        rutas = {f["r"]: f for f in self.inventario("nas-media")[1]}
        self.assertTrue(rutas["movies/Pelicula (2020)/pelicula.mkv"]["h"].startswith("rapida:"))
        self.assertEqual(rutas["respaldos/yggdrasil/r.tar.gz"]["h"], fafnir.huella_completa(self.t / "nas/respaldos/yggdrasil/r.tar.gz"))
        self.assertEqual(rutas[".DS_Store"]["k"], "basura-sistema")
        self.assertNotIn("h", rutas[".DS_Store"], "a la basura del sistema no se le calcula huella")
        self.assertEqual(rutas["movies/Pelicula (2020)/pelicula.mkv"]["k"], "video")

    def test_la_misma_pelicula_tiene_la_misma_huella_en_otro_disco(self):
        self.todo()
        h = {n: [f["h"] for f in self.inventario(n)[1] if f["r"].endswith("pelicula.mkv")][0] for n in ("nas-media", "wd-medios", "samsung")}
        self.assertEqual(len(set(h.values())), 1)

    def test_reutiliza_la_huella_de_lo_que_no_cambio(self):
        config = fafnir.cargar_config(self.config)
        u = next(x for x in config["ubicacion"] if x["nombre"] == "wd-medios")
        _, leidos, reutilizados = fafnir.escanear_ubicacion(config, u, config["estado"], 1)
        self.assertEqual((leidos, reutilizados), (2, 0))
        _, leidos, reutilizados = fafnir.escanear_ubicacion(config, u, config["estado"], 2)
        self.assertEqual((leidos, reutilizados), (0, 2))
        doc = self.t / "wd/personal/doc.pdf"
        doc.write_bytes(b"cambiado, y con otro tamano")
        _, leidos, reutilizados = fafnir.escanear_ubicacion(config, u, config["estado"], 3)
        self.assertEqual((leidos, reutilizados), (1, 1), "lo que cambió se vuelve a leer")

    def test_una_huella_rapida_vieja_no_vale_si_la_coleccion_pide_la_completa(self):
        config = fafnir.cargar_config(self.config)
        u = next(x for x in config["ubicacion"] if x["nombre"] == "wd-medios")
        fafnir.escanear_ubicacion(config, u, config["estado"], 1)
        for col in config["coleccion"]:
            if col["nombre"] == "peliculas":
                col["huella"] = "completa"
        _, leidos, _ = fafnir.escanear_ubicacion(config, u, config["estado"], 2)
        self.assertEqual(leidos, 1, "la película se vuelve a leer entera")

    def test_una_ubicacion_obligatoria_que_falta_hace_fallar(self):
        import shutil
        shutil.rmtree(self.t / "samsung")
        rc, _, err = self.fafnir("escanear", "--host", "nidavellir")
        self.assertEqual(rc, 1)
        self.assertIn("samsung", err)
        self.assertIsNotNone(self.inventario("wd-medios")[0], "las demás se inventarían igual")


class PruebasCatalogo(Base):
    def test_copias_por_medio_riesgo_y_politica(self):
        self.todo()
        a = fafnir.analizar(fafnir.abrir_catalogo(fafnir.cargar_config(self.config)))
        pel, per = a["colecciones"]["peliculas"], a["colecciones"]["personal"]
        self.assertEqual(pel["bytes"], 3 * MIB, "la película cuenta una vez como contenido")
        self.assertEqual(pel["bytes_repetidos"], 2 * 3 * MIB, "y dos copias de más")
        self.assertEqual(pel["bytes_bajo_politica"], 0)
        proyecto = len(b"print('solo en el disco que falla')")
        doc = len(b"solo en el WD")
        respaldo = len(b"respaldo de servicio")
        self.assertEqual(per["bytes_en_riesgo"], proyecto, "solo en el Samsung")
        self.assertEqual(per["bytes_bajo_politica"], proyecto + doc + respaldo, "pide 2 copias sanas y tienen 0 o 1")
        self.assertIn("nas + samsung + wd", a["repetidos"])

    def test_las_reglas_se_recalculan_al_catalogar(self):
        self.todo()
        cfg = self.config.read_text(encoding="utf-8").replace('reglas = ["nas-media:TV/"]', 'reglas = []')
        self.config.write_text(cfg, encoding="utf-8")
        self.fafnir("catalogar")
        db = sqlite3.connect(self.t / "catalogo.db")
        self.assertEqual(db.execute("SELECT coleccion FROM fichero WHERE ruta = 'TV/Serie/S01E01.mkv'").fetchone()[0], "sin-coleccion")

    def test_informe_en_texto_y_json(self):
        self.todo()
        rc, out, _ = self.fafnir("informe")
        self.assertEqual(rc, 0)
        self.assertIn("SOLO EN MEDIOS EN RIESGO", out)
        self.assertIn("samsung:Projects/proyecto.py", out)
        rc, out, _ = self.fafnir("informe", "--json")
        j = json.loads(out)
        self.assertEqual(j["ubicaciones"]["externo"]["escaneado"], None, "el externo sin conectar no tiene inventario")

    def test_metricas_para_mimir(self):
        self.todo()
        self.assertEqual(self.fafnir("metricas")[0], 0)
        prom = (self.t / "thor/fafnir.prom").read_text(encoding="utf-8")
        proyecto = len(b"print('solo en el disco que falla')")
        self.assertIn(f'fafnir_coleccion_en_riesgo_bytes{{coleccion="personal",copias_minimas="2"}} {proyecto}', prom)
        self.assertIn('fafnir_inventario_timestamp_seconds{ubicacion="samsung",host="nidavellir",opcional="0"}', prom)
        self.assertNotIn('ubicacion="externo"', prom.split("fafnir_ubicacion_bytes")[0], "un externo sin conectar no avisa")

    def test_una_ubicacion_fija_nunca_inventariada_sale_con_0(self):
        self.assertEqual(self.fafnir("escanear", "--host", "midgard")[0], 0)   # nidavellir aún no
        self.fafnir("catalogar")
        self.fafnir("metricas")
        prom = (self.t / "thor/fafnir.prom").read_text(encoding="utf-8")
        self.assertIn('fafnir_inventario_timestamp_seconds{ubicacion="wd-medios",host="nidavellir",opcional="0"} 0', prom)
        self.assertEqual(oct((self.t / "thor/fafnir.prom").stat().st_mode & 0o777), "0o644")

    def test_sin_catalogo_lo_dice(self):
        with self.assertRaises(SystemExit):
            self.fafnir("informe")


class PruebasMover(Base):
    def test_copia_verificada_y_borrado_solo_con_la_opcion(self):
        origen, destino = self.t / "nas/movies", self.t / "wd/peliculas-nuevas"
        rc, out, _ = self.fafnir("mover", str(origen), str(destino))
        self.assertEqual(rc, 0)
        copia = destino / "Pelicula (2020)/pelicula.mkv"
        self.assertEqual(copia.read_bytes(), self.pelicula)
        self.assertEqual(copia.stat().st_mtime_ns, (origen / "Pelicula (2020)/pelicula.mkv").stat().st_mtime_ns, "conserva la fecha")
        self.assertTrue((origen / "Pelicula (2020)/pelicula.mkv").exists(), "sin --borrar-origen no se borra nada")
        rc, out, _ = self.fafnir("mover", str(origen), str(destino), "--borrar-origen")
        self.assertEqual(rc, 0)
        self.assertIn("(1 ya estaban)", out, "lo ya copiado se verifica y no se vuelve a copiar")
        self.assertFalse((origen / "Pelicula (2020)").exists(), "origen vaciado, carpetas incluidas")
        self.assertTrue(origen.exists(), "la raíz del origen se conserva")
        self.assertEqual(len(list((self.t / "estado/movimientos").glob("*.jsonl"))), 2, "un diario por movimiento")

    def test_una_copia_que_no_coincide_no_borra_nada(self):
        origen, destino = self.t / "nas/movies", self.t / "wd/peliculas-nuevas"
        real = fafnir.huella_completa
        falsa = lambda ruta: "sha256:otra" if str(ruta).endswith(".fafnir-tmp") else real(ruta)
        with mock.patch.object(fafnir, "huella_completa", side_effect=falsa):
            rc, _, err = self.fafnir("mover", str(origen), str(destino), "--borrar-origen")
        self.assertEqual(rc, 1)
        self.assertIn("no se borra nada", err)
        self.assertTrue((origen / "Pelicula (2020)/pelicula.mkv").exists())
        self.assertFalse((destino / "Pelicula (2020)/pelicula.mkv").exists(), "no queda una copia mala con el nombre bueno")
        self.assertEqual(list(destino.rglob("*.fafnir-tmp")), [], "ni el temporal")

    def test_origen_y_destino_no_pueden_contenerse(self):
        with self.assertRaises(SystemExit):
            self.fafnir("mover", str(self.t / "nas"), str(self.t / "nas/dentro"))


class PruebasConfig(Base):
    def test_un_medio_sin_declarar_se_rechaza(self):
        self.config.write_text(self.config.read_text(encoding="utf-8").replace('medio = "wd"', 'medio = "otro"'), encoding="utf-8")
        with self.assertRaises(SystemExit):
            fafnir.cargar_config(self.config)

    def test_la_configuracion_de_ejemplo_es_valida(self):
        c = fafnir.cargar_config(Path(__file__).resolve().parent.parent / "fafnir.ejemplo.toml")
        self.assertEqual({u["host"] for u in c["ubicacion"]}, {"midgard", "nidavellir"})
        self.assertEqual(fafnir.coleccion_de(c, "nas-media", "movies/X/x.mkv")["nombre"], "peliculas")
        self.assertEqual(fafnir.coleccion_de(c, "nas-respaldos", "bragi/r.tar")["huella"], "completa")

    def test_tipos(self):
        self.assertEqual(fafnir.tipo_de("a/b.MKV"), "video")
        self.assertEqual(fafnir.tipo_de("respaldo.part1.rar"), "comprimido")
        self.assertEqual(fafnir.tipo_de("respaldo.r01"), "comprimido")
        self.assertEqual(fafnir.tipo_de("._algo.mkv"), "basura-sistema")
        self.assertEqual(fafnir.tipo_de("LEEME"), "otros")


if __name__ == "__main__":
    unittest.main()
