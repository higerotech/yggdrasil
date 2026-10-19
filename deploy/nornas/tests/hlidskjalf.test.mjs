// Pruebas de Hlidskjalf, el tablero de pared: los nodos function del resumen (src/hlidskjalf-*.js),
// las herramientas que settings.js da al sandbox, el pintado de la página (hlidskjalf/tablero.js)
// y la CSP del flujo generado. Ejecutar dentro de la imagen de Node-RED (settings.js necesita
// bcryptjs): node --test deploy/nornas/tests/flujo.test.mjs deploy/nornas/tests/hlidskjalf.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { createServer } from "node:http";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const leer = (ruta) => readFileSync(new URL(ruta, import.meta.url), "utf8");
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
// Edades en segundos: entre montar los datos y ejecutar el nodo puede pasar un segundo.
const casi = (real, esperado, msj) => assert.ok(Math.abs(real - esperado) <= 2, `${msj}: ${real} frente a ${esperado}`);

process.env.NORNAS_CREDENTIAL_SECRET ||= "prueba";
process.env.NORNAS_ADMIN_PASSWORD ||= "prueba";
const { functionGlobalContext: herramientas } = require("../settings.js");
const tablero = require("../hlidskjalf/tablero.js");

// Ejecuta un nodo function como Node-RED: cuerpo asíncrono con env, global, context y node simulados.
function nodo(fichero, { entorno = {}, globales = herramientas } = {}) {
    const cuerpo = new AsyncFunction("msg", "env", "global", "context", "node", leer(`../src/${fichero}`));
    const ctx = new Map();
    const registro = { avisos: [] };
    const sim = {
        env: { get: (k) => entorno[k] },
        global: { get: (k) => globales[k] },
        context: { get: (k) => ctx.get(k), set: (k, v) => ctx.set(k, v) },
        node: { warn: (t) => registro.avisos.push(t), status: () => {} },
    };
    return { ejecutar: (msg) => cuerpo(msg, sim.env, sim.global, sim.context, sim.node), registro };
}

const TOKEN = "a".repeat(64);
const peticion = (auth) => ({ req: { headers: auth ? { authorization: auth } : {} } });

test("autorizar: sin HLIDSKJALF_TOKEN el tablero queda cerrado (503), no abierto", async () => {
    for (const entorno of [{}, { HLIDSKJALF_TOKEN: "corto" }]) {
        const [ok, err] = await nodo("hlidskjalf-autorizar.js", { entorno }).ejecutar(peticion("Bearer corto"));
        assert.equal(ok, null);
        assert.equal(err.statusCode, 503);
    }
});

test("autorizar: token incorrecto o ausente → 401; correcto → pasa", async () => {
    const n = nodo("hlidskjalf-autorizar.js", { entorno: { HLIDSKJALF_TOKEN: TOKEN } });
    for (const auth of [null, "Bearer " + "b".repeat(64), "Bearer " + TOKEN.slice(1), TOKEN, "Basic " + TOKEN]) {
        const [ok, err] = await n.ejecutar(peticion(auth));
        assert.equal(ok, null, String(auth));
        assert.equal(err.statusCode, 401);
    }
    const [ok, err] = await n.ejecutar(peticion("Bearer " + TOKEN));
    assert.ok(ok);
    assert.equal(err, null);
    assert.equal(ok.headers["Cache-Control"], "no-store");
});

test("herramientas: secretoIgual compara en tiempo constante sin romperse con longitudes distintas", () => {
    assert.equal(herramientas.secretoIgual("abc", "abc"), true);
    assert.equal(herramientas.secretoIgual("abc", "abd"), false);
    assert.equal(herramientas.secretoIgual("abc", "abcd"), false);
    assert.equal(herramientas.secretoIgual("ñ", "n"), false);
});

test("herramientas: consultarJson devuelve el JSON, falla con HTTP de error y respeta el tiempo máximo", async () => {
    const servidor = createServer((req, res) => {
        if (req.url === "/ok") { res.setHeader("Content-Type", "application/json"); res.end('{"a":1}'); }
        else if (req.url === "/lento") setTimeout(() => res.end("{}"), 2000);
        else { res.statusCode = 500; res.end("x"); }
    });
    await new Promise((r) => servidor.listen(0, "127.0.0.1", r));
    const base = `http://127.0.0.1:${servidor.address().port}`;
    try {
        assert.deepEqual(await herramientas.consultarJson(`${base}/ok`), { a: 1 });
        await assert.rejects(herramientas.consultarJson(`${base}/error`), /HTTP 500/);
        const t0 = Date.now();
        await assert.rejects(herramientas.consultarJson(`${base}/lento`, 200));
        assert.ok(Date.now() - t0 < 1500, "corta por tiempo");
    } finally {
        servidor.closeAllConnections();
        servidor.close();
    }
});

// --- Resumen -------------------------------------------------------------------------------
const AHORA = Math.round(Date.now() / 1000);
const s = (nombre, etiquetas, valor) => ({ metric: { __name__: nombre, ...etiquetas }, value: [AHORA, String(valor)] });
const SERIES = [
    s("wan:up", { wan: "wan1" }, 1), s("wan:up", { wan: "wan2" }, 0),
    s("yggdrasil_wan_en_ruta", { wan: "wan1" }, 1), s("yggdrasil_wan_en_ruta", { wan: "wan2" }, 1),
    s("wan:latencia_p95:5m", { wan: "wan1" }, 0.01234), s("wan:perdida_pct:5m", { wan: "wan1" }, 0),
    s("wan:disponibilidad:30d", { wan: "wan1" }, 0.971),
    s("wan_throughput_mbps", { wan: "wan1", direccion: "down", job: "sleipnir" }, 912.4),
    s("wan_throughput_mbps", { wan: "wan2", direccion: "up", job: "sleipnir" }, 102),
    s("wan:slo_throughput_mbps", { wan: "wan2", direccion: "up" }, 400),
    s("wan_throughput_ultima_medicion_timestamp_seconds", { wan: "wan1", direccion: "down" }, AHORA - 3600),
    s("wan_throughput_medicion_en_curso", { wan: "wan1", job: "sleipnir" }, 0),
    s("wan_throughput_medicion_en_curso", { wan: "wan2", job: "sleipnir" }, 1),
    s("hogar:up", {}, 1), s("hogar:disponibilidad:30d", {}, 0.9997),
    s("yggdrasil_thor_timestamp_seconds", { job: "thor" }, AHORA - 30),
    s("yggdrasil_smart_lectura_ok", { disco: "sda" }, 1), s("yggdrasil_smart_salud", { disco: "sda" }, 1),
    s("yggdrasil_smart_atributo", { disco: "sda", id: "197", nombre: "Current_Pending_Sector" }, 16),
    s("yggdrasil_smart_atributo", { disco: "sda", id: "1", nombre: "Raw_Read_Error_Rate" }, 99),
    s("yggdrasil_fs_montado", { punto: "/mnt/nas/respaldos" }, 1),
    s("yggdrasil_fs_tamano_bytes", { punto: "/mnt/nas/respaldos" }, 3.93e12),
    s("yggdrasil_fs_libre_bytes", { punto: "/mnt/nas/respaldos" }, 1.857e11),
    s("yggdrasil_fs_montado", { punto: "/" }, 1),
    // el SSD de datos: se cayó del bus con SMART limpio
    s("yggdrasil_smart_lectura_ok", { disco: "sdb" }, 1), s("yggdrasil_smart_salud", { disco: "sdb" }, 1),
    s("yggdrasil_disco_rotacional", { disco: "sda" }, 1), s("yggdrasil_disco_rotacional", { disco: "sdb" }, 0),
    s("yggdrasil_disco_errores_kernel_15m", { disco: "sda" }, 0), s("yggdrasil_disco_errores_kernel_15m", { disco: "sdb" }, 5),
    s("yggdrasil_fs_montado", { punto: "/srv/rapido" }, 1),
    s("yggdrasil_servicio_ok", { tipo: "unidad", nombre: "docker.service" }, 1),
    s("yggdrasil_servicio_ok", { tipo: "contenedor", nombre: "yggdrasil-prometheus" }, 1),
    s("yggdrasil_servicio_ok", { tipo: "contenedor", nombre: "yggdrasil-grafana" }, 0),
    s("yggdrasil_respaldo_ultimo_exito_timestamp_seconds", { respaldo: "bifrost" }, AHORA - 2 * 3600),
    s("yggdrasil_respaldo_ultimo_exito_timestamp_seconds", { respaldo: "yggdrasil" }, AHORA - 5 * 3600),
];
const ALERTAS = [
    { labels: { alertname: "NasSeLlena", severity: "warning" }, annotations: { resumen: "NAS <b>lleno</b>" }, startsAt: "2026-10-16T10:00:00Z" },
    { labels: { alertname: "WanCaida", severity: "critical", wan: "wan2" }, annotations: { resumen: "wan2 caída" }, startsAt: "2026-10-16T12:00:00Z" },
    { labels: { alertname: "WanNoAptaLlamadas", severity: "info", wan: "wan1" }, annotations: {}, startsAt: "2026-10-16T09:00:00Z" },
];
function fuentes({ mimir = true, gjallarhorn = true, series = SERIES } = {}) {
    const urls = [];
    return {
        urls,
        consultarJson: async (url) => {
            urls.push(url);
            if (url.includes("/api/v1/query")) {
                if (!mimir) throw new Error("connect ECONNREFUSED");
                return { status: "success", data: { resultType: "vector", result: series } };
            }
            if (!gjallarhorn) throw new Error("timeout");
            return ALERTAS;
        },
    };
}

test("resumen: una sola consulta a Mimir con todas las series y las alertas activas sin silenciar", async () => {
    const f = fuentes();
    await nodo("hlidskjalf-resumen.js", { globales: f }).ejecutar({});
    assert.equal(f.urls.length, 2);
    const q = decodeURIComponent(f.urls[0].split("query=")[1]);
    assert.match(q, /^\{__name__=~".*wan:up.*yggdrasil_servicio_ok.*"\}$/);
    assert.ok(f.urls[0].startsWith("http://mimir:9090/"));
    assert.equal(f.urls[1], "http://gjallarhorn:9093/api/v2/alerts?active=true&silenced=false&inhibited=false");
});

test("resumen: WAN, host, servicios y alertas ordenadas por gravedad", async () => {
    const { payload: r, statusCode, headers } = await nodo("hlidskjalf-resumen.js", { globales: fuentes() }).ejecutar({});
    assert.equal(statusCode, 200);
    assert.equal(headers["Cache-Control"], "no-store");
    assert.deepEqual(r.fuentes, { mimir: true, gjallarhorn: true });
    assert.deepEqual(r.wan.map((w) => w.wan), ["wan1", "wan2"]);
    const [w1, w2] = r.wan;
    assert.equal(w1.up, 1);
    assert.equal(w1.latencia_p95_ms, 12.3);
    assert.equal(w1.bajada_mbps, 912.4);
    casi(w1.medicion_hace_s, 3600, "medicion_hace_s");
    assert.equal(w1.sleipnir_midiendo, 0);
    assert.equal(w2.sleipnir_midiendo, 1);
    assert.equal(w2.up, 0);
    assert.equal(w2.en_ruta, 1);
    assert.equal(w2.subida_mbps, 102);
    assert.equal(w2.slo_subida_mbps, 400);
    assert.equal(w2.bajada_mbps, null);
    assert.deepEqual(r.hogar, { up: 1, disponibilidad_30d: 0.9997 });
    casi(r.host.thor_hace_s, 30, "thor_hace_s");
    assert.equal(r.host.discos[0].pendientes, 16);
    assert.ok(!("Raw_Read_Error_Rate" in r.host.discos[0]), "solo los atributos que enseña el tablero");
    assert.deepEqual(r.host.discos.map((d) => [d.disco, d.rotacional, d.errores_kernel]), [["sda", 1, 0], ["sdb", 0, 5]]);
    assert.deepEqual(r.host.fs.map((f) => f.punto), ["/", "/mnt/nas/respaldos", "/srv/rapido"]);
    assert.deepEqual(r.host.respaldos.map((x) => [x.nombre, x.hace_h]), [["yggdrasil", 5], ["bifrost", 2]], "el de Yggdrasil primero");
    assert.equal(r.host.respaldo.hace_h, 5, "respaldo: el de Yggdrasil, para el tablero viejo");
    assert.deepEqual(r.servicios.map((x) => x.nombre), ["yggdrasil-grafana", "yggdrasil-prometheus", "docker.service"]);
    assert.deepEqual(r.alertas.map((a) => a.nombre), ["WanCaida", "NasSeLlena", "WanNoAptaLlamadas"]);
    assert.equal(r.alertas[2].resumen, "WanNoAptaLlamadas", "sin anotación usa el nombre");
});

test("resumen: el respaldo sin etiqueta de un Thor anterior es el de Yggdrasil", async () => {
    const series = SERIES.filter((x) => x.metric.__name__ !== "yggdrasil_respaldo_ultimo_exito_timestamp_seconds")
        .concat([s("yggdrasil_respaldo_ultimo_exito_timestamp_seconds", {}, AHORA - 7 * 3600)]);
    const { payload: r } = await nodo("hlidskjalf-resumen.js", { globales: fuentes({ series }) }).ejecutar({});
    assert.deepEqual(r.host.respaldos.map((x) => [x.nombre, x.hace_h]), [["yggdrasil", 7]]);
    assert.equal(r.host.respaldo.hace_h, 7);
});

test("resumen: si una fuente cae, su sección va vacía, fuentes lo dice y el aviso sale una vez", async () => {
    const n = nodo("hlidskjalf-resumen.js", { globales: fuentes({ mimir: false }) });
    const { payload: r } = await n.ejecutar({});
    assert.deepEqual(r.fuentes, { mimir: false, gjallarhorn: true });
    assert.deepEqual(r.wan, []);
    assert.deepEqual(r.servicios, []);
    assert.equal(r.alertas.length, 3);
    await n.ejecutar({});
    assert.equal(n.registro.avisos.length, 1);
    assert.match(n.registro.avisos[0], /Mimir no respondió \(connect ECONNREFUSED\)/);
});

// --- Página --------------------------------------------------------------------------------
const base = {
    generado: AHORA, fuentes: { mimir: true, gjallarhorn: true }, hogar: { up: 1 },
    wan: [], alertas: [], host: {}, servicios: [{ tipo: "contenedor", nombre: "yggdrasil-prometheus", ok: 1 }],
};

test("tablero: estado general, del peor caso al mejor", () => {
    const e = (cambios) => tablero.estadoGeneral({ ...base, ...cambios });
    assert.deepEqual(e({}), { nivel: "ok", texto: "Todo en orden" });
    assert.equal(e({ hogar: { up: 0 } }).texto, "Midgard sin internet");
    assert.equal(e({ fuentes: { mimir: false, gjallarhorn: true } }).texto, "Sin datos de Mimir");
    assert.deepEqual(e({ alertas: [{ severidad: "critical" }, { severidad: "warning" }] }), { nivel: "critico", texto: "1 alerta crítica" });
    assert.deepEqual(e({ servicios: [{ ok: 0 }, { ok: 0 }] }), { nivel: "critico", texto: "2 servicios caídos" });
    assert.deepEqual(e({ alertas: [{ severidad: "warning" }] }), { nivel: "aviso", texto: "1 alerta activa" });
    assert.equal(e({ alertas: [{ severidad: "info" }] }).nivel, "ok", "info no cambia el semáforo");
    assert.equal(e({ fuentes: { mimir: true, gjallarhorn: false } }).texto, "Sin datos de Gjallarhorn");
});

test("tablero: niveles de WAN, NAS, disco y respaldo", () => {
    assert.equal(tablero.nivelWan({ up: 1, en_ruta: 1, perdida_pct: 0, latencia_p95_ms: 12 }), "ok");
    assert.equal(tablero.nivelWan({ up: 1, en_ruta: 0 }), "aviso");
    assert.equal(tablero.nivelWan({ up: 1, en_ruta: 1, latencia_p95_ms: 250 }), "aviso");
    assert.equal(tablero.nivelWan({ up: 0, en_ruta: 1 }), "critico");
    assert.equal(tablero.nivelWan({ up: null }), "nodato");
    assert.equal(tablero.nivelFs({ montado: 1, tamano_bytes: 100, libre_bytes: 4.7 }), "aviso");
    assert.equal(tablero.nivelFs({ montado: 1, tamano_bytes: 100, libre_bytes: 2 }), "critico");
    assert.equal(tablero.nivelFs({ montado: 1, tamano_bytes: 100, libre_bytes: 50 }), "ok");
    assert.equal(tablero.nivelFs({ montado: 0 }), "critico");
    assert.equal(tablero.nivelDisco({ lectura_ok: 1, salud: 1, pendientes: 16 }), "aviso");
    assert.equal(tablero.nivelDisco({ lectura_ok: 1, salud: 0 }), "critico");
    assert.equal(tablero.nivelDisco({ lectura_ok: 1, salud: 1, errores_kernel: 3 }), "critico", "errores del enlace con SMART limpio");
    assert.equal(tablero.nivelDisco({ lectura_ok: 1, salud: 1, errores_kernel: 0 }), "ok");
    assert.equal(tablero.nivelRespaldo({ hace_h: 30 }), "aviso");
    assert.equal(tablero.nivelRespaldo({ hace_h: 5 }), "ok");
});

test("tablero: el SSD, sus errores del enlace y un respaldo por fila", () => {
    const html = tablero.vistaHost({
        thor_hace_s: 30,
        discos: [{ disco: "sda", lectura_ok: 1, salud: 1, rotacional: 1 }, { disco: "sdb", lectura_ok: 1, salud: 1, rotacional: 0, errores_kernel: 5 }],
        fs: [{ punto: "/srv/rapido", montado: 0 }],
        respaldo: { hace_h: 5 },
        respaldos: [{ nombre: "yggdrasil", hace_h: 5 }, { nombre: "bifrost", hace_h: 30 }, { nombre: "<x>", hace_h: null },
            { nombre: "hermod", hace_h: 1 }, { nombre: "andvari", hace_h: 2 }, { nombre: "otro", hace_h: 3 }],
    });
    assert.match(html, /fila ok"><span>Respaldo Hermod<\/span>/);
    assert.match(html, /fila ok"><span>Respaldo Andvari<\/span>/);
    assert.match(html, /fila ok"><span>Respaldo Otro<\/span>/, "uno sin nombre propio sale con mayúscula");
    assert.match(html, /fila ok"><span>Disco sda · HDD</);
    assert.match(html, /fila critico"><span>Disco sdb · SSD<\/span><b>5 errores del enlace en 15 min · /);
    assert.match(html, /fila critico"><span>SSD<\/span><b>NO MONTADO/);
    assert.match(html, /fila ok"><span>Respaldo Yggdrasil<\/span><b>hace 5 h/);
    assert.match(html, /fila aviso"><span>Respaldo Bifröst<\/span><b>hace 30 h/);
    assert.match(html, /fila aviso"><span>Respaldo &lt;x&gt;<\/span><b>sin constancia/);
    // un resumen anterior: solo `respaldo`, una fila sin nombre como antes
    assert.match(tablero.vistaHost({ thor_hace_s: 30, respaldo: { hace_h: 5 } }), /fila ok"><span>Respaldo<\/span><b>hace 5 h/);
});

test("tablero: el texto del servidor se escapa (una anotación no puede inyectar HTML)", () => {
    const html = tablero.vistaAlertas([{ nombre: "<img src=x onerror=alert(1)>", severidad: "warning", resumen: "NAS <b>lleno</b>", desde: "2026-10-16T10:00:00Z" }], AHORA, true);
    assert.ok(!html.includes("<img"));
    assert.ok(html.includes("&lt;img src=x onerror=alert(1)&gt;"));
    assert.ok(html.includes("NAS &lt;b&gt;lleno&lt;/b&gt;"));
    assert.match(tablero.vistaAlertas([], AHORA, false), /Gjallarhorn no responde/);
});

test("tablero: formato en español y nombres nórdicos de los servicios", () => {
    assert.equal(tablero.numero(912.4), "912");
    assert.equal(tablero.numero(12345.6, 1), "12.345,6");
    assert.equal(tablero.porcentaje(0.9997, 2), "99,97 %");
    assert.equal(tablero.bytes(1.857e11), "185,7 GB");
    assert.equal(tablero.bytes(3.93e12), "3,93 TB");
    assert.equal(tablero.duracion(45), "45 s");
    assert.equal(tablero.duracion(3 * 3600), "3 h");
    assert.equal(tablero.duracion(3 * 86400), "3 d");
    const html = tablero.vistaServicios([{ tipo: "contenedor", nombre: "yggdrasil-prometheus", ok: 1 }, { tipo: "unidad", nombre: "wan-watchdog.timer", ok: 0 }]);
    assert.match(html, /Mimir<small>prometheus<\/small>/);
    assert.match(html, /servicio critico.*>wan-watchdog<small>temporizador<\/small>/);
});

test("tablero: la tarjeta de wan2 caída con la subida bajo el SLO", () => {
    const html = tablero.vistaWan({ wan: "wan2", up: 0, en_ruta: 1, subida_mbps: 102, slo_subida_mbps: 400 });
    assert.match(html, /tarjeta wan critico/);
    assert.match(html, /CAÍDA/);
    assert.match(html, /chip critico">en la ruta/);
    assert.match(html, /vel aviso">↑ 102<small> \/ 400 Mbps/);
});

test("tablero: la pérdida que provoca Sleipnir al medir no pone la WAN en ámbar", () => {
    const base = { wan: "wan2", up: 1, en_ruta: 1, perdida_pct: 5, latencia_p95_ms: 260 };
    // midiendo ahora, y dentro de la ventana de 5 min (+30 s) tras terminar
    assert.equal(tablero.nivelWan({ ...base, sleipnir_midiendo: 1, medicion_hace_s: 3 * 3600 }), "ok");
    assert.equal(tablero.nivelWan({ ...base, sleipnir_midiendo: 0, medicion_hace_s: 120 }), "ok");
    assert.equal(tablero.nivelWan({ ...base, sleipnir_midiendo: 0, medicion_hace_s: 329 }), "ok");
    // pasada la ventana, la pérdida ya es del enlace
    assert.equal(tablero.nivelWan({ ...base, sleipnir_midiendo: 0, medicion_hace_s: 330 }), "aviso");
    assert.equal(tablero.nivelWan({ ...base, medicion_hace_s: null }), "aviso", "sin datos de Sleipnir no se disculpa nada");
    // una caída o una WAN fuera de la ruta se ven igual aunque Sleipnir esté midiendo
    assert.equal(tablero.nivelWan({ ...base, up: 0, sleipnir_midiendo: 1 }), "critico");
    assert.equal(tablero.nivelWan({ ...base, en_ruta: 0, sleipnir_midiendo: 1 }), "aviso");

    assert.match(tablero.vistaWan({ ...base, sleipnir_midiendo: 1 }), /chip medicion">Sleipnir midiendo<\/span><span class="chip ok">en la ruta/);
    assert.match(tablero.vistaWan({ ...base, sleipnir_midiendo: 0, medicion_hace_s: 90 }), /chip medicion">tras medir la velocidad/);
    assert.ok(!/chip medicion/.test(tablero.vistaWan({ ...base, sleipnir_midiendo: 0, medicion_hace_s: 3600 })));
});

// --- Flujo generado ------------------------------------------------------------------------
test("flujo: la página lleva CSS y JS en línea y la CSP admite exactamente esos dos bloques", () => {
    const flujo = JSON.parse(leer("../flows/heimdall-alertas.json"));
    const pagina = flujo.find((n) => n.id === "t.pagina");
    const respuesta = flujo.find((n) => n.id === "t.pagina.res");
    const bloque = (etiqueta) => new RegExp(`<${etiqueta}>([\\s\\S]*?)</${etiqueta}>`).exec(pagina.template)[1];
    const hash = (t) => `'sha256-${createHash("sha256").update(t, "utf8").digest("base64")}'`;
    const csp = respuesta.headers["Content-Security-Policy"];
    assert.equal(bloque("script"), leer("../hlidskjalf/tablero.js"));
    assert.ok(csp.includes(`script-src ${hash(bloque("script"))};`));
    assert.ok(csp.includes(`style-src ${hash(bloque("style"))};`));
    assert.ok(csp.startsWith("default-src 'none'"));
    assert.ok(!/unsafe-inline/.test(csp));
    assert.ok(!/ style=/.test(pagina.template), "sin estilos en línea: la CSP los bloquearía");
    assert.ok(flujo.some((n) => n.type === "tab" && n.id === "hlidskjalf.tab"));
});
