// Nodo function "Alertmanager → estados MQTT". Traduce el webhook de Gjallarhorn a los eventos
// MQTT del contrato de Yggdrasil (docs/02-design/architecture.md):
//   midgard/wan/<id>/estado          saludable|degradado|caido|recuperando   (retained)
//   midgard/wan/<id>/apto_llamadas   si|no                                   (retained)
//   midgard/hogar/internet/estado    ok|degradado|caido                      (retained)
//   midgard/wan/<id>/alerta          JSON {alerta, severidad, desde, detalle} (no retained)
// Salidas: 1 = MQTT (Ratatosk), 2 = notificación push, 3 = respuesta HTTP al webhook.
// Push: un aviso por episodio. Gjallarhorn reenvía el grupo entero en cada cambio del grupo y cada
// repeat_interval (4 h); sin recordar qué se avisó ya, cada reenvío sería un push repetido.
const RECUPERACION_MS = 5 * 60 * 1000;   // Recuperando -> Saludable tras 5 min estable
const OLVIDO_MS = 7 * 24 * 3600 * 1000;  // una huella sin resolución en 7 d se olvida: recordatorio semanal
const PRIORIDAD = { critical: 4, warning: 3, info: 2 };   // prioridades de ntfy (1..5)
// WANs de la plataforma: una WAN de la que no se ha sabido nada cuenta como saludable, para que
// la caida de una sola no deje al hogar en "caido" (YGG_WANS en el entorno del contenedor).
const WANS = (env.get("YGG_WANS") || "wan1,wan2").split(",").map(s => s.trim()).filter(Boolean);
const alertas = (msg.payload && msg.payload.alerts) || [];
const estados = flow.get("estado_wan") || {};
const apto = flow.get("apto_wan") || {};          // ultimo valor conocido de apto_llamadas por WAN
const degradada = flow.get("degradada_wan") || {};  // WanDegradada firing por WAN (para salir de Recuperando)
const timers = context.get("timers") || {};
const avisados = flow.get("avisados") || {};      // huella -> instante del push, mientras siga firing
const ahora = Date.now();
for (const fp of Object.keys(avisados)) if (ahora - avisados[fp] > OLVIDO_MS) delete avisados[fp];
const mqtt = [];
const push = [];

function calcHogar(e) {
    const v = WANS.map(w => e[w] || "saludable");
    if (v.every(x => x === "caido")) return "caido";
    if (v.some(x => x === "saludable")) return "ok";
    return "degradado";
}
function m(topic, payload, retain) {
    return { topic, payload: typeof payload === "string" ? payload : JSON.stringify(payload), qos: 1, retain: !!retain };
}
function fijar(wan, estado) { estados[wan] = estado; mqtt.push(m(`midgard/wan/${wan}/estado`, estado, true)); }
function aviso(titulo, texto, prioridad, etiquetas) {
    push.push({ topic: titulo, payload: texto, prioridad: prioridad || 3, etiquetas: etiquetas || [] });
}

for (const a of alertas) {
    const l = a.labels || {}, an = a.annotations || {};
    const wan = l.wan, nombre = l.alertname, firing = a.status === "firing";
    if (!nombre) continue;
    const prio = PRIORIDAD[l.severity] || 3;
    // nueva = primera vez que se ve firing; resuelta = se había avisado y ahora se resuelve
    const fp = a.fingerprint || JSON.stringify(l);
    const nueva = firing && !avisados[fp];
    const resuelta = !firing && !!avisados[fp];
    if (firing) { if (nueva) avisados[fp] = ahora; } else delete avisados[fp];
    if (!wan) {                                   // p. ej. SondaCaida o las de Bragi: aviso y resolución
        if (nueva) aviso(`Heimdall: ${nombre}`, an.resumen || "", prio, ["warning"]);
        if (resuelta) aviso(`Heimdall: ${nombre} resuelta`, an.resumen || "", 2, ["white_check_mark"]);
        continue;
    }
    if (firing) mqtt.push(m(`midgard/wan/${wan}/alerta`, { alerta: nombre, severidad: l.severity || "", desde: a.startsAt, detalle: an.resumen || "" }, false));
    switch (nombre) {
        case "WanCaida":
            if (timers[wan]) { clearTimeout(timers[wan]); delete timers[wan]; }
            if (firing) {
                fijar(wan, "caido");
                mqtt.push(m(`midgard/wan/${wan}/apto_llamadas`, "no", true));   // caida => no apta
                if (nueva) aviso(`Heimdall: ${wan} CAÍDA`, an.descripcion || an.resumen || "", prio, ["rotating_light"]);
            } else {
                fijar(wan, "recuperando");
                timers[wan] = setTimeout(() => {
                    const e = flow.get("estado_wan") || {};
                    const t = context.get("timers") || {};
                    delete t[wan]; context.set("timers", t);
                    if (e[wan] !== "recuperando") return;
                    // Si la degradacion sigue activa al terminar la recuperacion, el enlace queda Degradado
                    const final = ((flow.get("degradada_wan") || {})[wan]) ? "degradado" : "saludable";
                    e[wan] = final; flow.set("estado_wan", e);
                    const ap = (flow.get("apto_wan") || {})[wan];
                    node.send([[m(`midgard/wan/${wan}/estado`, final, true),
                                m(`midgard/wan/${wan}/apto_llamadas`, ap === false ? "no" : "si", true),
                                m("midgard/hogar/internet/estado", calcHogar(e), true)], null, null]);
                }, RECUPERACION_MS);
                // Sin exigir "resuelta": tras reiniciar Nornas no recuerda la caída y el aviso importa igual
                aviso(`Heimdall: ${wan} recuperando`, "Las sondas responden; si sigue estable 5 min pasa a saludable.",
                      2, ["white_check_mark"]);
            }
            break;
        case "WanDegradada":
            degradada[wan] = firing;
            if (estados[wan] === "caido" || estados[wan] === "recuperando") break;
            fijar(wan, firing ? "degradado" : "saludable");
            if (nueva) aviso(`Heimdall: ${wan} degradada`, an.resumen || "", prio, ["warning"]);
            break;
        case "WanNoAptaLlamadas":
            apto[wan] = !firing;
            mqtt.push(m(`midgard/wan/${wan}/apto_llamadas`, firing ? "no" : "si", true));
            break;
        case "WanThroughputBajo":
        case "SleipnirSinMedicion":
            if (nueva) aviso(`Heimdall: ${nombre} en ${wan}`, an.resumen || "", prio, ["warning"]);
            break;
        default:
            break;
    }
}
flow.set("estado_wan", estados);
flow.set("apto_wan", apto);
flow.set("degradada_wan", degradada);
flow.set("avisados", avisados);
context.set("timers", timers);
mqtt.push(m("midgard/hogar/internet/estado", calcHogar(estados), true));
msg.statusCode = 200;
msg.payload = { ok: true, alertas: alertas.length };
return [mqtt, push, msg];
