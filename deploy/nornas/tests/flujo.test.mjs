// Pruebas de los nodos function del flujo Heimdall (src/*.js), sin Node-RED: cada fichero se
// ejecuta como cuerpo de función con env, flow, context y node simulados, como hace Node-RED.
// Ejecutar: node --test deploy/nornas/tests/
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const src = (f) => readFileSync(new URL(`../src/${f}`, import.meta.url), "utf8");

function nodo(fichero, entorno = {}) {
    const cuerpo = new Function("msg", "env", "flow", "context", "node", "setTimeout", "clearTimeout", src(fichero));
    const almacen = (m) => ({ get: (k) => m.get(k), set: (k, v) => m.set(k, v) });
    const flowM = new Map(), ctxM = new Map();
    const registro = { avisos: [], estados: [] };
    const nodeSim = { warn: (t) => registro.avisos.push(t), status: (s) => registro.estados.push(s), send: () => {} };
    const ejecutar = (msg) => cuerpo(msg, { get: (k) => entorno[k] }, almacen(flowM), almacen(ctxM), nodeSim,
        () => 0, () => {});
    return { ejecutar, flowM, registro };
}

const alerta = (nombre, estado, extra = {}) => ({
    status: estado,
    fingerprint: extra.fingerprint || `fp-${nombre}-${extra.wan || ""}`,
    labels: { alertname: nombre, severity: extra.severity || "warning", ...(extra.wan ? { wan: extra.wan } : {}) },
    annotations: { resumen: extra.resumen || `${nombre} resumen` },
    startsAt: "2026-10-05T00:00:00Z",
});
const webhook = (...alertas) => ({ payload: { alerts: alertas } });
const pushes = (salida) => salida[1];

test("una alerta sin WAN avisa una sola vez aunque Gjallarhorn la reenvíe", () => {
    const t = nodo("traducir.js");
    assert.equal(pushes(t.ejecutar(webhook(alerta("BragiCaido", "firing")))).length, 1);
    assert.equal(pushes(t.ejecutar(webhook(alerta("BragiCaido", "firing")))).length, 0);
    assert.equal(pushes(t.ejecutar(webhook(alerta("BragiCaido", "firing")))).length, 0);
});

test("la resolución de una alerta avisada manda un push de prioridad baja", () => {
    const t = nodo("traducir.js");
    t.ejecutar(webhook(alerta("SondaCaida", "firing")));
    const p = pushes(t.ejecutar(webhook(alerta("SondaCaida", "resolved"))));
    assert.equal(p.length, 1);
    assert.equal(p[0].topic, "Heimdall: SondaCaida resuelta");
    assert.equal(p[0].prioridad, 2);
    // y un nuevo episodio vuelve a avisar
    assert.equal(pushes(t.ejecutar(webhook(alerta("SondaCaida", "firing")))).length, 1);
});

test("una resolución de algo que nunca se avisó no manda nada", () => {
    const t = nodo("traducir.js");
    assert.equal(pushes(t.ejecutar(webhook(alerta("SondaCaida", "resolved")))).length, 0);
});

test("dos instancias de la misma alerta se distinguen por huella", () => {
    const t = nodo("traducir.js");
    const a = alerta("SondaCaida", "firing", { fingerprint: "a" });
    const b = alerta("SondaCaida", "firing", { fingerprint: "b" });
    assert.equal(pushes(t.ejecutar(webhook(a))).length, 1);
    assert.equal(pushes(t.ejecutar(webhook(a, b))).length, 1);   // solo la nueva
});

test("WanCaida: push crítico una vez, MQTT en cada lote y aviso de recuperación", () => {
    const t = nodo("traducir.js");
    const caida = alerta("WanCaida", "firing", { wan: "wan2", severity: "critical" });
    const s1 = t.ejecutar(webhook(caida));
    assert.equal(pushes(s1).length, 1);
    assert.equal(pushes(s1)[0].topic, "Heimdall: wan2 CAÍDA");
    assert.equal(pushes(s1)[0].prioridad, 4);
    assert.ok(s1[0].some((m) => m.topic === "midgard/wan/wan2/estado" && m.payload === "caido"));
    const s2 = t.ejecutar(webhook(caida));
    assert.equal(pushes(s2).length, 0);
    assert.ok(s2[0].some((m) => m.topic === "midgard/wan/wan2/estado" && m.payload === "caido"));
    const s3 = t.ejecutar(webhook(alerta("WanCaida", "resolved", { wan: "wan2" })));
    assert.equal(pushes(s3)[0].topic, "Heimdall: wan2 recuperando");
    assert.ok(s3[0].some((m) => m.topic === "midgard/wan/wan2/estado" && m.payload === "recuperando"));
});

test("WanDegradada reenviada cada 4 h no repite el push", () => {
    const t = nodo("traducir.js");
    const d = alerta("WanDegradada", "firing", { wan: "wan2" });
    assert.equal(pushes(t.ejecutar(webhook(d))).length, 1);
    assert.equal(pushes(t.ejecutar(webhook(d))).length, 0);
});

test("WanNoAptaLlamadas no manda push", () => {
    const t = nodo("traducir.js");
    assert.equal(pushes(t.ejecutar(webhook(alerta("WanNoAptaLlamadas", "firing", { wan: "wan1", severity: "info" })))).length, 0);
});

test("una huella de más de 7 días se olvida y vuelve a avisar", () => {
    const t = nodo("traducir.js");
    t.ejecutar(webhook(alerta("BragiCaido", "firing")));
    const av = t.flowM.get("avisados");
    for (const k of Object.keys(av)) av[k] -= 8 * 24 * 3600 * 1000;
    assert.equal(pushes(t.ejecutar(webhook(alerta("BragiCaido", "firing")))).length, 1);
});

const URL_PRUEBA = "https://ntfy.example/tema-de-prueba-123";

test("ntfy: sin NTFY_URL no envía nada", () => {
    const t = nodo("ntfy.js");
    assert.equal(t.ejecutar({ topic: "x", payload: "y" }), null);
});

test("ntfy: una NTFY_URL sin tema se rechaza", () => {
    const t = nodo("ntfy.js", { NTFY_URL: "https://ntfy.example/" });
    assert.equal(t.ejecutar({ topic: "x", payload: "y" }), null);
});

test("ntfy: publica JSON en la raíz con tema, título UTF-8, prioridad y etiquetas", () => {
    const t = nodo("ntfy.js", { NTFY_URL: URL_PRUEBA });
    const m = t.ejecutar({ topic: "Heimdall: wan2 CAÍDA", payload: "sin ruta", prioridad: 4, etiquetas: ["rotating_light"] });
    assert.equal(m.url, "https://ntfy.example/");
    assert.equal(m.method, "POST");
    assert.deepEqual(JSON.parse(m.payload), {
        topic: "tema-de-prueba-123", title: "Heimdall: wan2 CAÍDA", message: "sin ruta", priority: 4, tags: ["rotating_light"],
    });
    assert.ok(t.registro.estados.every((s) => !s.text.includes("tema-de-prueba")), "el tema no sale en el estado");
});

test("respuesta de ntfy: 200 en silencio; error y ENOTFOUND avisan sin la URL", () => {
    for (const [codigo, avisa] of [[200, false], [429, true], ["ENOTFOUND", true]]) {
        const t = nodo("ntfy-respuesta.js");
        t.ejecutar({ statusCode: codigo, topic: "Heimdall: x", url: "https://ntfy.example/", payload: "{\"topic\":\"tema-de-prueba-123\"}" });
        assert.equal(t.registro.avisos.length, avisa ? 1 : 0, `código ${codigo}`);
        assert.ok(t.registro.avisos.every((a) => !a.includes("tema-de-prueba")));
    }
});
