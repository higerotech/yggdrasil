#!/usr/bin/env python3
"""Genera flows/heimdall-alertas.json (importable en Node-RED) a partir de src/*.js.

El JSON es el artefacto que se importa; el JavaScript de los nodos function vive en src/ para
poder revisarlo. Ejecutar tras editar src/: python3 generar-flujo.py
"""
import base64
import hashlib
import json
from pathlib import Path

AQUI = Path(__file__).parent
TAB = "heimdall.tab"

INFO = (
    "Flujo Heimdall → Nornas. Lo importa automáticamente nornas-init en el primer arranque del Compose "
    "de Yggdrasil e inyecta las credenciales MQTT del usuario 'nornas' (Ratatosk, ACL midgard/#). "
    "NORNAS_WEBHOOK_TOKEN llega por el entorno del contenedor. La salida 2 (push) publica en ntfy con "
    "NTFY_URL (vacía = push desactivado), un aviso por episodio (huellas en el contexto avisados). "
    "El estado por WAN vive en el contexto de flujo (estado_wan). Para volver a importar una versión nueva del flujo, borrar la pestaña Heimdall y "
    "relanzar nornas-init."
)


def fn(id_, name, src, outputs, x, y, wires, z=TAB):
    return {"id": id_, "type": "function", "z": z, "name": name, "func": (AQUI / "src" / src).read_text(encoding="utf-8"),
            "outputs": outputs, "timeout": 0, "noerr": 0, "initialize": "", "finalize": "", "libs": [],
            "x": x, "y": y, "wires": wires}


TAB_H = "hlidskjalf.tab"
INFO_H = (
    "Hlidskjalf, el tablero de pared de midgard (ADR-0007). GET /hlidskjalf/ sirve la página (HTML, CSS y "
    "JS en línea, con CSP por hash) y GET /hlidskjalf/resumen el JSON que pinta, a partir de una consulta a "
    "Mimir y de las alertas activas de Gjallarhorn por la red interna. El resumen exige el token de solo "
    "lectura HLIDSKJALF_TOKEN (Bearer); sin él configurado responde 503. Fuentes en deploy/nornas/hlidskjalf/."
)
FUENTES = ("autorizar.js", "traducir.js", "ntfy.js", "ntfy-respuesta.js", "hlidskjalf-autorizar.js", "hlidskjalf-resumen.js")
PAGINA = ("index.html", "tablero.css", "tablero.js")


def pagina():
    """index.html con tablero.css y tablero.js en línea, y la CSP que solo admite esos dos bloques."""
    d = AQUI / "hlidskjalf"
    css = (d / "tablero.css").read_text(encoding="utf-8")
    js = (d / "tablero.js").read_text(encoding="utf-8")
    html = (d / "index.html").read_text(encoding="utf-8")
    for marca, contenido in (("/* tablero.css */", css), ("/* tablero.js */", js)):
        assert html.count(marca) == 1, marca
        html = html.replace(marca, contenido)
    h = lambda t: "'sha256-" + base64.b64encode(hashlib.sha256(t.encode("utf-8")).digest()).decode() + "'"
    csp = (f"default-src 'none'; script-src {h(js)}; style-src {h(css)}; connect-src 'self'; img-src 'self' data:; "
           "base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
    return html, csp


HTML, CSP = pagina()
# Revision del flujo = hash de las fuentes; nornas-init reimporta las pestañas cuando cambia.
REV = hashlib.sha256(b"".join([(AQUI / "src" / f).read_bytes() for f in sorted(FUENTES)] +
                              [(AQUI / "hlidskjalf" / f).read_bytes() for f in PAGINA])).hexdigest()[:12]

flow = [
    {"id": TAB, "type": "tab", "label": "Heimdall · alertas SLA", "disabled": False, "info": INFO,
     "env": [{"name": "HEIMDALL_FLOW_REV", "type": "str", "value": REV}]},
    {"id": "ratatosk.broker", "type": "mqtt-broker", "name": "Ratatosk", "broker": "ratatosk", "port": "1883",
     "clientid": "nornas-heimdall", "autoConnect": True, "usetls": False, "protocolVersion": "4", "keepalive": "60",
     "cleansession": True, "autoUnsubscribe": True,
     "birthTopic": "midgard/nornas/heimdall/estado", "birthQos": "1", "birthRetain": "true", "birthPayload": "online", "birthMsg": {},
     "closeTopic": "midgard/nornas/heimdall/estado", "closeQos": "1", "closeRetain": "true", "closePayload": "offline", "closeMsg": {},
     "willTopic": "midgard/nornas/heimdall/estado", "willQos": "1", "willRetain": "true", "willPayload": "offline", "willMsg": {},
     "userProps": "", "sessionExpiry": ""},
    {"id": "h.comentario", "type": "comment", "z": TAB, "name": "Gjallarhorn (Alertmanager) → webhook → estados MQTT en Ratatosk",
     "info": INFO, "x": 330, "y": 40, "wires": []},
    {"id": "h.in", "type": "http in", "z": TAB, "name": "POST /heimdall/alertas", "url": "/heimdall/alertas", "method": "post",
     "upload": False, "swaggerDoc": "", "x": 150, "y": 120, "wires": [["h.auth"]]},
    fn("h.auth", "Autorizar (Bearer NORNAS_WEBHOOK_TOKEN)", "autorizar.js", 2, 420, 120, [["h.map"], ["h.res401"]]),
    {"id": "h.res401", "type": "http response", "z": TAB, "name": "401", "statusCode": "401", "headers": {}, "x": 690, "y": 200, "wires": []},
    fn("h.map", "Alertmanager → estados MQTT", "traducir.js", 3, 720, 120, [["h.mqtt"], ["h.push", "h.ntfy"], ["h.res200"]]),
    {"id": "h.mqtt", "type": "mqtt out", "z": TAB, "name": "Ratatosk midgard/#", "topic": "", "qos": "", "retain": "",
     "respTopic": "", "contentType": "", "userProps": "", "correl": "", "expiry": "", "broker": "ratatosk.broker",
     "x": 1010, "y": 60, "wires": []},
    {"id": "h.push", "type": "debug", "z": TAB, "name": "Notificación push (copia en el panel de depuración)", "active": True,
     "tosidebar": True, "console": False, "tostatus": False, "complete": "true", "targetType": "full", "statusVal": "",
     "statusType": "auto", "x": 1090, "y": 120, "wires": []},
    fn("h.ntfy", "Formatear ntfy (NTFY_URL)", "ntfy.js", 1, 1090, 240, [["h.ntfy.req"]]),
    {"id": "h.ntfy.req", "type": "http request", "z": TAB, "name": "POST ntfy", "method": "use", "ret": "txt",
     "paytoqs": "ignore", "url": "", "tls": "", "persist": False, "proxy": "", "insecureHTTPParser": False,
     "authType": "", "senderr": False, "headers": [], "x": 1310, "y": 240, "wires": [["h.ntfy.res"]]},
    fn("h.ntfy.res", "Respuesta de ntfy", "ntfy-respuesta.js", 1, 1500, 240, [[]]),
    {"id": "h.res200", "type": "http response", "z": TAB, "name": "200", "statusCode": "200", "headers": {}, "x": 1010, "y": 180, "wires": []},

    # --- Hlidskjalf: tablero de pared ---
    {"id": TAB_H, "type": "tab", "label": "Hlidskjalf · tablero de pared", "disabled": False, "info": INFO_H, "env": []},
    {"id": "t.comentario", "type": "comment", "z": TAB_H, "name": "Tablet de pared → página y resumen de midgard (solo lectura)",
     "info": INFO_H, "x": 330, "y": 40, "wires": []},
    {"id": "t.pagina.in", "type": "http in", "z": TAB_H, "name": "GET /hlidskjalf", "url": "/hlidskjalf", "method": "get",
     "upload": False, "swaggerDoc": "", "x": 140, "y": 120, "wires": [["t.pagina"]]},
    {"id": "t.pagina", "type": "template", "z": TAB_H, "name": "Página (deploy/nornas/hlidskjalf)", "field": "payload",
     "fieldType": "msg", "format": "html", "syntax": "plain", "template": HTML, "output": "str", "x": 400, "y": 120,
     "wires": [["t.pagina.res"]]},
    {"id": "t.pagina.res", "type": "http response", "z": TAB_H, "name": "200 HTML", "statusCode": "200",
     "headers": {"Content-Type": "text/html; charset=utf-8", "Content-Security-Policy": CSP, "Cache-Control": "no-cache",
                 "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer"},
     "x": 660, "y": 120, "wires": []},
    {"id": "t.resumen.in", "type": "http in", "z": TAB_H, "name": "GET /hlidskjalf/resumen", "url": "/hlidskjalf/resumen",
     "method": "get", "upload": False, "swaggerDoc": "", "x": 160, "y": 220, "wires": [["t.auth"]]},
    fn("t.auth", "Autorizar tablero (HLIDSKJALF_TOKEN)", "hlidskjalf-autorizar.js", 2, 430, 220, [["t.resumen"], ["t.resumen.res"]], z=TAB_H),
    fn("t.resumen", "Resumen de midgard (Mimir + Gjallarhorn)", "hlidskjalf-resumen.js", 1, 720, 220, [["t.resumen.res"]], z=TAB_H),
    {"id": "t.resumen.res", "type": "http response", "z": TAB_H, "name": "JSON", "statusCode": "", "headers": {},
     "x": 980, "y": 280, "wires": []},
]

salida = AQUI / "flows" / "heimdall-alertas.json"
salida.parent.mkdir(parents=True, exist_ok=True)
salida.write_text(json.dumps(flow, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")
json.loads(salida.read_text(encoding="utf-8"))
print(f"{salida.relative_to(AQUI.parent.parent)}: {len(flow)} nodos, {salida.stat().st_size} bytes, rev {REV}")
