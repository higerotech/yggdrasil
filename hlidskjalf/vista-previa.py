#!/usr/bin/env python3
"""vista-previa.py: sirve el tablero en desarrollo para probarlo en la tablet real.

La tablet llega al PC por `adb reverse` (lo monta vista-previa.sh). El servidor arma la página
igual que deploy/nornas/generar-flujo.py, con CSS y JS en línea y la CSP por hash, a partir de
deploy/nornas/hlidskjalf/ tal como está en disco, y le añade un medidor. A los 4 s de pintar, el
medidor informa de qué fila queda recortada, tapada o fuera de la pantalla.

    GET  /hlidskjalf/          la página, con el medidor
    GET  /hlidskjalf/resumen   el escenario elegido (hlidskjalf/escenarios/*.json, o un JSON propio)
    POST /medida               lo que mide la página; va a build/vista-previa/medidas.jsonl

El escenario se elige con `vista-previa.sh probar <fichero>`, que escribe su ruta en
build/vista-previa/escenario y el servidor lo relee en cada petición. Las alertas del escenario
conservan su antigüedad: «desde» se desplaza lo mismo que «generado» hasta ahora.

    python3 hlidskjalf/vista-previa.py [puerto]        # 8099 por defecto
    python3 hlidskjalf/vista-previa.py --informe        # resume la última medida; sale con 1 si algo se pierde
"""
import base64
import hashlib
import json
import os
import sys
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

AQUI = Path(__file__).resolve().parent
PAGINA = AQUI.parent / "deploy" / "nornas" / "hlidskjalf"
TRABAJO = AQUI / "build" / "vista-previa"

# Mide en el WebView de la tablet (Chromium 81: ES2017, sin optional chaining)
MEDIDOR = """
(function () {
  function rect(e) { var r = e.getBoundingClientRect(); return { t: Math.round(r.top), b: Math.round(r.bottom) }; }
  function texto(e) { return e.textContent.replace(/\\s+/g, " ").trim().slice(0, 60); }
  function medir() {
    var out = { vw: innerWidth, vh: innerHeight, paneles: [], recortes: [], tapados: [], fuera: [] };
    Array.prototype.forEach.call(document.querySelectorAll(".panel, .tarjeta"), function (p) {
      var h = p.querySelector("h3, h2"), nombre = h ? texto(h) : p.className;
      var pr = p.getBoundingClientRect();
      out.paneles.push({ panel: nombre, rect: rect(p), alto_contenido: p.scrollHeight, alto_visible: p.clientHeight });
      Array.prototype.forEach.call(p.querySelectorAll(".fila, li, .servicio, .velocidades, .cifras"), function (f) {
        var fr = f.getBoundingClientRect();
        if (fr.bottom > pr.bottom + 1) out.recortes.push({ panel: nombre, elemento: texto(f), px: Math.round(fr.bottom - pr.bottom) });
      });
    });
    Array.prototype.forEach.call(document.querySelectorAll(".hogar, .fila, li, .servicio, .tarjeta header, .velocidades"), function (e) {
      var r = e.getBoundingClientRect();
      if (r.width === 0) return;
      var x = r.left + r.width / 2, y = r.top + r.height / 2;
      if (y > innerHeight || x > innerWidth) { out.fuera.push(texto(e)); return; }
      var tope = document.elementFromPoint(x, y);
      if (tope && tope !== e && !e.contains(tope)) out.tapados.push({ elemento: texto(e), por: String(tope.className || tope.tagName) });
    });
    Array.prototype.forEach.call(document.querySelectorAll(".fila > b, .servicio, .alertas li"), function (e) {
      if (e.scrollWidth > e.clientWidth + 1) out.recortes.push({ panel: "a lo ancho", elemento: texto(e), px: e.scrollWidth - e.clientWidth });
    });
    var ocultas = document.getElementById("host-ocultas");
    out.pie_host = ocultas && !ocultas.hidden ? ocultas.textContent : null;
    var enviar = function () { fetch("/medida", { method: "POST", body: JSON.stringify(out) }); };
    if (typeof navigator.getBattery !== "function") { out.bateria = null; enviar(); return; }
    navigator.getBattery().then(function (b) { out.bateria = { nivel: b.level, cargando: b.charging }; enviar(); }, enviar);
  }
  setTimeout(medir, 4000);
})();
"""


def pagina():
    css = (PAGINA / "tablero.css").read_text(encoding="utf-8")
    js = (PAGINA / "tablero.js").read_text(encoding="utf-8")
    html = (PAGINA / "index.html").read_text(encoding="utf-8")
    for marca, contenido in (("/* tablero.css */", css), ("/* tablero.js */", js)):
        assert html.count(marca) == 1, marca
        html = html.replace(marca, contenido)
    html = html.replace("</body>", "<script>" + MEDIDOR + "</script></body>")
    h = lambda t: "'sha256-" + base64.b64encode(hashlib.sha256(t.encode("utf-8")).digest()).decode() + "'"
    csp = (f"default-src 'none'; script-src {h(js)} {h(MEDIDOR)}; style-src {h(css)}; connect-src 'self'; "
           "img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
    return html, csp


def escenario():
    r = json.loads(Path((TRABAJO / "escenario").read_text(encoding="utf-8").strip()).read_text(encoding="utf-8"))
    ahora = int(time.time())
    delta = ahora - int(r.get("generado") or ahora)
    for a in r.get("alertas") or []:
        try:
            desde = datetime.fromisoformat(a["desde"].replace("Z", "+00:00")).timestamp() + delta
            a["desde"] = datetime.fromtimestamp(desde, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        except (KeyError, ValueError, AttributeError):
            pass
    r["generado"] = ahora
    return r


class Servidor(ThreadingHTTPServer):
    # En Windows, SO_REUSEADDR deja a un segundo proceso escuchar en el mismo puerto sin error, y
    # las peticiones siguen yendo al primero: una vista previa vieja contestaría por la nueva.
    allow_reuse_address = os.name != "nt"


class Manejador(BaseHTTPRequestHandler):
    def responder(self, codigo, cuerpo, tipo, extra=None):
        datos = cuerpo.encode("utf-8")
        self.send_response(codigo)
        self.send_header("Content-Type", tipo)
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(datos)))
        self.end_headers()
        self.wfile.write(datos)

    def do_GET(self):
        ruta = self.path.split("?")[0]
        try:
            if ruta in ("/hlidskjalf", "/hlidskjalf/"):
                html, csp = pagina()
                self.responder(200, html, "text/html; charset=utf-8", {"Content-Security-Policy": csp})
            elif ruta == "/hlidskjalf/resumen":
                self.responder(200, json.dumps(escenario(), ensure_ascii=False), "application/json")
            else:
                self.send_error(404)
        except (OSError, ValueError, AssertionError) as e:
            # El tablero enseña `error` en la cabecera: así se ve en la tablet qué falla
            self.responder(500, json.dumps({"error": f"vista previa: {e}"}, ensure_ascii=False), "application/json")

    def do_POST(self):
        datos = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode("utf-8")
        with open(TRABAJO / "medidas.jsonl", "a", encoding="utf-8") as f:
            f.write(json.dumps({"hora": time.strftime("%H:%M:%S"), "escenario": (TRABAJO / "escenario").read_text(encoding="utf-8").strip(),
                                "medida": json.loads(datos)}, ensure_ascii=False) + "\n")
        self.responder(200, "{}", "application/json")

    def log_message(self, *a):
        pass


def informe():
    lineas = (TRABAJO / "medidas.jsonl").read_text(encoding="utf-8").splitlines()
    m = json.loads(lineas[-1])
    d = m["medida"]
    print(f"{m['hora']} {Path(m['escenario']).name}  pantalla {d['vw']}x{d['vh']}  batería {d.get('bateria')}")
    for p in d["paneles"]:
        sobra = p["alto_contenido"] - p["alto_visible"]
        print(f"  {p['panel'][:34]:34} {p['rect']['t']:4}-{p['rect']['b']:<4}" + (f"  desborda {sobra} px" if sobra > 1 else ""))
    if d.get("pie_host"):
        print("  pie de Host:", d["pie_host"])
    perdidas = [("recortado", x) for x in d["recortes"]] + [("tapado", x) for x in d["tapados"]] + [("fuera", x) for x in d["fuera"]]
    for tipo, x in perdidas:
        print(f"  {tipo}: {x}")
    print("  nada recortado, tapado ni fuera de la pantalla" if not perdidas else f"  {len(perdidas)} elementos no se ven enteros")
    return 1 if perdidas else 0


if __name__ == "__main__":
    if sys.argv[1:2] == ["--informe"]:
        sys.exit(informe())
    TRABAJO.mkdir(parents=True, exist_ok=True)
    puerto = int(sys.argv[1]) if len(sys.argv) > 1 else 8099
    print(f"vista previa en http://127.0.0.1:{puerto}/hlidskjalf/ (fuente: {PAGINA})", flush=True)
    Servidor(("127.0.0.1", puerto), Manejador).serve_forever()
