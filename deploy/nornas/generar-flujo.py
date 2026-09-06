#!/usr/bin/env python3
"""Genera flows/heimdall-alertas.json (importable en Node-RED) a partir de src/*.js.

El JSON es el artefacto que se importa; el JavaScript de los nodos function vive en src/ para
poder revisarlo. Ejecutar tras editar src/: python3 generar-flujo.py
"""
import json
from pathlib import Path

AQUI = Path(__file__).parent
TAB = "heimdall.tab"

INFO = (
    "Flujo Heimdall → Nornas. Lo importa automáticamente nornas-init en el primer arranque del Compose "
    "de Yggdrasil e inyecta las credenciales MQTT del usuario 'nornas' (Ratatosk, ACL midgard/#). "
    "NORNAS_WEBHOOK_TOKEN llega por el entorno del contenedor. Pendiente manual: conectar la salida 2 "
    "(push) al mecanismo de notificación de la casa. El estado por WAN vive en el contexto de flujo "
    "(estado_wan). Para volver a importar una versión nueva del flujo, borrar la pestaña Heimdall y "
    "relanzar nornas-init."
)


def fn(id_, name, src, outputs, x, y, wires):
    return {"id": id_, "type": "function", "z": TAB, "name": name, "func": (AQUI / "src" / src).read_text(encoding="utf-8"),
            "outputs": outputs, "timeout": 0, "noerr": 0, "initialize": "", "finalize": "", "libs": [],
            "x": x, "y": y, "wires": wires}


flow = [
    {"id": TAB, "type": "tab", "label": "Heimdall · alertas SLA", "disabled": False, "info": INFO, "env": []},
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
    fn("h.map", "Alertmanager → estados MQTT", "traducir.js", 3, 720, 120, [["h.mqtt"], ["h.push"], ["h.res200"]]),
    {"id": "h.mqtt", "type": "mqtt out", "z": TAB, "name": "Ratatosk midgard/#", "topic": "", "qos": "", "retain": "",
     "respTopic": "", "contentType": "", "userProps": "", "correl": "", "expiry": "", "broker": "ratatosk.broker",
     "x": 1010, "y": 60, "wires": []},
    {"id": "h.push", "type": "debug", "z": TAB, "name": "Notificación push (conectar aquí Telegram, ntfy o similar)", "active": True,
     "tosidebar": True, "console": False, "tostatus": False, "complete": "true", "targetType": "full", "statusVal": "",
     "statusType": "auto", "x": 1090, "y": 120, "wires": []},
    {"id": "h.res200", "type": "http response", "z": TAB, "name": "200", "statusCode": "200", "headers": {}, "x": 1010, "y": 180, "wires": []},
]

salida = AQUI / "flows" / "heimdall-alertas.json"
salida.parent.mkdir(parents=True, exist_ok=True)
salida.write_text(json.dumps(flow, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")
json.loads(salida.read_text(encoding="utf-8"))
print(f"{salida.relative_to(AQUI.parent.parent)}: {len(flow)} nodos, {salida.stat().st_size} bytes")
