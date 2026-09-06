// Nodo function "Alertmanager → estados MQTT". Traduce el webhook de Gjallarhorn a los eventos
// MQTT del contrato de Yggdrasil (docs/02-design/architecture.md):
//   midgard/wan/<id>/estado          saludable|degradado|caido|recuperando   (retained)
//   midgard/wan/<id>/apto_llamadas   si|no                                   (retained)
//   midgard/hogar/internet/estado    ok|degradado|caido                      (retained)
//   midgard/wan/<id>/alerta          JSON {alerta, severidad, desde, detalle} (no retained)
// Salidas: 1 = MQTT (Ratatosk), 2 = notificación push, 3 = respuesta HTTP al webhook.
const RECUPERACION_MS = 5 * 60 * 1000;   // Recuperando -> Saludable tras 5 min estable
const alertas = (msg.payload && msg.payload.alerts) || [];
const estados = flow.get("estado_wan") || {};
const timers = context.get("timers") || {};
const mqtt = [];
const push = [];

function calcHogar(e) {
    const v = Object.values(e);
    if (v.length === 0) return "ok";
    if (v.every(x => x === "caido")) return "caido";
    if (v.some(x => x === "saludable")) return "ok";
    return "degradado";
}
function m(topic, payload, retain) {
    return { topic, payload: typeof payload === "string" ? payload : JSON.stringify(payload), qos: 1, retain: !!retain };
}
function fijar(wan, estado) { estados[wan] = estado; mqtt.push(m(`midgard/wan/${wan}/estado`, estado, true)); }
function aviso(titulo, texto) { push.push({ topic: titulo, payload: texto }); }

for (const a of alertas) {
    const l = a.labels || {}, an = a.annotations || {};
    const wan = l.wan, nombre = l.alertname, firing = a.status === "firing";
    if (!nombre) continue;
    if (!wan) {                                   // p. ej. SondaCaida: solo aviso
        if (firing) aviso(`Heimdall: ${nombre}`, an.resumen || "");
        continue;
    }
    if (firing) mqtt.push(m(`midgard/wan/${wan}/alerta`, { alerta: nombre, severidad: l.severity || "", desde: a.startsAt, detalle: an.resumen || "" }, false));
    switch (nombre) {
        case "WanCaida":
            if (timers[wan]) { clearTimeout(timers[wan]); delete timers[wan]; }
            if (firing) {
                fijar(wan, "caido");
                aviso(`Heimdall: ${wan} CAÍDA`, an.descripcion || an.resumen || "");
            } else {
                fijar(wan, "recuperando");
                timers[wan] = setTimeout(() => {
                    const e = flow.get("estado_wan") || {};
                    const t = context.get("timers") || {};
                    delete t[wan]; context.set("timers", t);
                    if (e[wan] !== "recuperando") return;
                    e[wan] = "saludable"; flow.set("estado_wan", e);
                    node.send([[m(`midgard/wan/${wan}/estado`, "saludable", true), m("midgard/hogar/internet/estado", calcHogar(e), true)], null, null]);
                }, RECUPERACION_MS);
                aviso(`Heimdall: ${wan} recuperando`, "Las sondas responden; si sigue estable 5 min pasa a saludable.");
            }
            break;
        case "WanDegradada":
            if (estados[wan] === "caido" || estados[wan] === "recuperando") break;
            fijar(wan, firing ? "degradado" : "saludable");
            if (firing) aviso(`Heimdall: ${wan} degradada`, an.resumen || "");
            break;
        case "WanNoAptaLlamadas":
            mqtt.push(m(`midgard/wan/${wan}/apto_llamadas`, firing ? "no" : "si", true));
            break;
        case "WanThroughputBajo":
        case "SleipnirSinMedicion":
            if (firing) aviso(`Heimdall: ${nombre} en ${wan}`, an.resumen || "");
            break;
        default:
            break;
    }
}
flow.set("estado_wan", estados);
context.set("timers", timers);
mqtt.push(m("midgard/hogar/internet/estado", calcHogar(estados), true));
msg.statusCode = 200;
msg.payload = { ok: true, alertas: alertas.length };
return [mqtt, push, msg];
