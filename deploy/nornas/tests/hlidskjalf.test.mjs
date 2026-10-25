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
    assert.match(q, /^\{__name__=~".*wan:up.*yggdrasil_servicio_ok.*"\} or up\{job="thor"\}$/);
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

test("resumen: otro host con Thor va aparte y no se mezcla con midgard (los dos tienen un sda)", async () => {
    const n = { job: "thor", host: "nidavellir" };
    const series = SERIES.concat([
        s("up", { job: "thor", instance: "thor:9471" }, 1),
        s("up", { ...n, instance: "192.168.10.2:9471" }, 1),
        s("yggdrasil_thor_timestamp_seconds", n, AHORA - 20),
        s("yggdrasil_arranque_timestamp_seconds", n, AHORA - 7 * 3600),
        s("yggdrasil_arranque_timestamp_seconds", { job: "thor" }, AHORA - 9 * 86400),
        s("yggdrasil_cpu_temperatura_celsius", n, 41.5),
        s("yggdrasil_smart_lectura_ok", { ...n, disco: "sda" }, 1), s("yggdrasil_smart_salud", { ...n, disco: "sda" }, 1),
        s("yggdrasil_smart_atributo", { ...n, disco: "sda", id: "197", nombre: "Current_Pending_Sector" }, 8),
        s("yggdrasil_disco_rotacional", { ...n, disco: "sda" }, 1),
        s("yggdrasil_fs_montado", { ...n, punto: "/srv/medios/wd" }, 1),
        s("yggdrasil_fs_tamano_bytes", { ...n, punto: "/srv/medios/wd" }, 1e12),
        s("yggdrasil_fs_libre_bytes", { ...n, punto: "/srv/medios/wd" }, 7.5e11),
        s("yggdrasil_servicio_ok", { ...n, tipo: "unidad", nombre: "docker.service" }, 0),
    ]);
    const { payload: r } = await nodo("hlidskjalf-resumen.js", { globales: fuentes({ series }) }).ejecutar({});
    assert.equal(r.host.discos.find((d) => d.disco === "sda").pendientes, 16, "el sda de midgard sigue siendo el suyo");
    assert.deepEqual(r.host.fs.map((f) => f.punto), ["/", "/mnt/nas/respaldos", "/srv/rapido"]);
    assert.deepEqual(r.servicios.map((x) => x.nombre), ["yggdrasil-grafana", "yggdrasil-prometheus", "docker.service"]);
    casi(r.host.arranque_hace_s, 9 * 86400, "arranque de midgard");
    assert.equal(r.hosts.length, 1, "midgard no se cuenta como otro host");
    const [h] = r.hosts;
    assert.equal(h.nombre, "nidavellir");
    assert.equal(h.up, 1);
    casi(h.thor_hace_s, 20, "thor_hace_s de nidavellir");
    casi(h.arranque_hace_s, 7 * 3600, "arranque de nidavellir");
    assert.equal(h.cpu_temperatura_c, 42);
    assert.deepEqual(h.discos.map((d) => [d.disco, d.pendientes, d.rotacional]), [["sda", 8, 1]]);
    assert.deepEqual(h.fs.map((f) => [f.punto, f.libre_bytes]), [["/srv/medios/wd", 7.5e11]]);
    assert.deepEqual(h.servicios, [{ tipo: "unidad", nombre: "docker.service", ok: 0 }]);
});

test("resumen: un host colgado sigue en la lista por su up, sin datos viejos", async () => {
    const series = SERIES.concat([s("up", { job: "thor", host: "nidavellir", instance: "192.168.10.2:9471" }, 0)]);
    const { payload: r } = await nodo("hlidskjalf-resumen.js", { globales: fuentes({ series }) }).ejecutar({});
    assert.deepEqual(r.hosts, [{ nombre: "nidavellir", up: 0, thor_hace_s: null, arranque_hace_s: null,
        cpu_temperatura_c: null, discos: [], fs: [], servicios: [] }]);
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

test("tablero: otro host, del que no responde al que está bien", () => {
    const bien = { nombre: "nidavellir", up: 1, thor_hace_s: 20, arranque_hace_s: 7 * 3600 };
    assert.deepEqual(tablero.estadoHost(bien), { nivel: "ok", texto: "encendido 7 h" });
    assert.deepEqual(tablero.estadoHost({ ...bien, arranque_hace_s: 240 }), { nivel: "aviso", texto: "arrancó hace 4 min" });
    assert.deepEqual(tablero.estadoHost({ ...bien, thor_hace_s: 720 }), { nivel: "aviso", texto: "datos de hace 12 min" });
    assert.deepEqual(tablero.estadoHost({ ...bien, thor_hace_s: null }), { nivel: "critico", texto: "SIN DATOS" });
    assert.deepEqual(tablero.estadoHost({ ...bien, up: 0 }), { nivel: "critico", texto: "NO RESPONDE" });
    assert.deepEqual(tablero.estadoHost({ ...bien, arranque_hace_s: null }), { nivel: "ok", texto: "en línea" });

    const e = (hosts) => tablero.estadoGeneral({ ...base, hosts });
    assert.deepEqual(e([bien]), { nivel: "ok", texto: "Todo en orden" });
    assert.deepEqual(e([{ ...bien, up: 0 }]), { nivel: "critico", texto: "Nidavellir no responde" });
    assert.deepEqual(e([{ ...bien, servicios: [{ tipo: "unidad", nombre: "docker.service", ok: 0 }] }]),
        { nivel: "critico", texto: "1 servicio caído" }, "sus servicios cuentan como los de midgard");
});

test("tablero: otro host es un bloque en el panel de midgard, con su cabecera y su detalle", () => {
    const h = {
        nombre: "nidavellir", up: 1, thor_hace_s: 20, arranque_hace_s: 7 * 3600, cpu_temperatura_c: 41,
        discos: [{ disco: "sdb", lectura_ok: 1, salud: 1, rotacional: 0, temperatura_c: 46 },
            { disco: "sdc", lectura_ok: 1, salud: 1, rotacional: 1, pendientes: 1, temperatura_c: 41 }],
        fs: [{ punto: "/srv/medios/wd", montado: 1, tamano_bytes: 1e12, libre_bytes: 7.5e11 }, { punto: "/mnt/nas/media", montado: 0 }],
        servicios: [{ tipo: "unidad", nombre: "docker.service", ok: 1 }, { tipo: "unidad", nombre: "cd-receiver.service", ok: 0 }],
    };
    const midgard = { discos: [{ disco: "sda", lectura_ok: 1, salud: 1, rotacional: 1 }] };
    const html = tablero.vistaHost(midgard, 0, [h]);
    assert.ok(html.indexOf("HDD sda") < html.indexOf("Nidavellir"), "midgard primero");
    assert.match(html, /<div class="fila ok otro-host"><span>Nidavellir<\/span><b>encendido 7 h · CPU 41 °C<\/b><\/div>/);
    assert.match(html, /<div class="fila ok"><span>SSD sdb<\/span><b>SMART sano · 46 °C<\/b><\/div>/);
    assert.match(html, /<div class="fila aviso"><span>HDD sdc<\/span><b>1 pendientes · 41 °C<\/b><\/div>/);
    assert.match(html, /<div class="fila critico"><span>NAS<\/span><b>NO MONTADO<\/b><\/div>/);
    assert.match(html, /<span>Medios<\/span><b>75,0 % libre/);
    assert.match(html, /<div class="fila critico"><span>Caído<\/span><b>cd-receiver<\/b><\/div>/);
    assert.match(html, /<div class="fila ok"><span>Servicios<\/span><b>1 en orden<\/b><\/div>/);
    assert.equal(tablero.vistaHost(midgard, 0), tablero.vistaHost(midgard, 0, []), "sin otros hosts, el panel de siempre");

    // Apretado, cada host agrupa lo suyo y la cabecera sigue diciendo de quién son las filas
    const denso = tablero.vistaHost(midgard, 1, [h]);
    assert.match(denso, /fila ok otro-host"><span>Nidavellir/);
    assert.equal((denso.match(/En orden/g) || []).length, 2, "un «En orden» por host");
    assert.ok(denso.indexOf("HDD sdc") > denso.indexOf("Nidavellir"), "el aviso de nidavellir, en su bloque");

    const calor = tablero.vistaHost(midgard, 0, [{ ...h, cpu_temperatura_c: 85 }]);
    assert.match(calor, /fila aviso otro-host"><span>Nidavellir<\/span><b>encendido 7 h · CPU 85 °C/, "la CPU caliente tiñe la otro-host");

    const mudo = tablero.vistaHost(midgard, 0, [{ ...h, up: 0 }]);
    assert.match(mudo, /<div class="fila critico otro-host"><span>Nidavellir<\/span><b>NO RESPONDE<\/b><\/div>/);
    assert.ok(!/CPU|sdb|Medios|Servicios/.test(mudo), "sin respuesta no enseña datos viejos");
    assert.match(tablero.vistaHost(midgard, 0, [{ ...h, nombre: "<b>x" }]), /otro-host"><span>&lt;b&gt;x<\/span>/, "el nombre se escapa");
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

test("tablero: el SSD con errores del enlace, y los respaldos en su panel en una sola línea", () => {
    const html = tablero.vistaHost({
        thor_hace_s: 30,
        discos: [{ disco: "sda", lectura_ok: 1, salud: 1, rotacional: 1 }, { disco: "sdb", lectura_ok: 1, salud: 1, rotacional: 0, errores_kernel: 5 }],
        fs: [{ punto: "/srv/rapido", montado: 0 }],
    });
    assert.match(html, /fila ok"><span>HDD sda</);
    assert.match(html, /fila critico"><span>SSD sdb<\/span><b>5 errores del enlace en 15 min</);
    assert.match(html, /fila critico"><span>SSD<\/span><b>NO MONTADO/);
    assert.ok(!/Respaldo/.test(html), "los respaldos ya no son una fila de Host");

    const resp = tablero.vistaRespaldos({
        respaldo: { hace_h: 5 },
        respaldos: [{ nombre: "yggdrasil", hace_h: 5 }, { nombre: "bifrost", hace_h: 30 }, { nombre: "<x>", hace_h: null },
            { nombre: "hermod", hace_h: 1 }, { nombre: "andvari", hace_h: 2 }, { nombre: "otro", hace_h: 3 }],
    });
    assert.match(resp, /<span class="ok"><small>Hermod<\/small>1 h<\/span>/);
    assert.match(resp, /<span class="ok"><small>Andvari<\/small>2 h<\/span>/);
    assert.match(resp, /<span class="ok"><small>Otro<\/small>3 h<\/span>/, "uno sin nombre propio sale con mayúscula");
    assert.match(resp, /<span class="ok"><small>Yggdrasil<\/small>5 h<\/span>/);
    assert.match(resp, /<span class="aviso"><small>Bifröst<\/small>30 h<\/span>/);
    assert.match(resp, /<span class="aviso"><small>&lt;x&gt;<\/small>sin constancia<\/span>/);
    // un resumen anterior: solo `respaldo`, que es el de Yggdrasil
    assert.equal(tablero.vistaRespaldos({ respaldo: { hace_h: 5 } }), '<span class="lista"><span class="ok"><small>Yggdrasil</small>5 h</span></span>');
});

test("tablero: el detalle del disco solo nombra los contadores que no están a cero", () => {
    assert.equal(tablero.detalleDisco({ lectura_ok: 1, salud: 1, pendientes: null, incorregibles: 0, reasignados: 0, temperatura_c: 43 }), "SMART sano · 43 °C");
    assert.equal(tablero.detalleDisco({ lectura_ok: 1, salud: 1, pendientes: 16, incorregibles: 16, reasignados: 0, temperatura_c: 35 }),
        "16 pendientes · 16 incorregibles · 35 °C");
    assert.equal(tablero.detalleDisco({ lectura_ok: 1, salud: 0, errores_kernel: 42, reasignados: 3 }),
        "42 errores del enlace en 15 min · SMART FALLA · 3 reasignados");
    assert.equal(tablero.detalleDisco({ lectura_ok: 0 }), "sin lectura SMART");
});

test("tablero: Host se aprieta empezando por lo que está bien y nunca esconde un aviso", () => {
    const h = {
        thor_hace_s: 30,
        discos: [{ disco: "sda", lectura_ok: 1, salud: 1, rotacional: 1, pendientes: 16, temperatura_c: 35 },
            { disco: "sdb", lectura_ok: 1, salud: 1, rotacional: 0, temperatura_c: 43 }],
        fs: [{ punto: "/", montado: 1, tamano_bytes: 100, libre_bytes: 86 }, { punto: "/mnt/nas/respaldos", montado: 1, tamano_bytes: 100, libre_bytes: 2 }],
    };
    const nombres = (html) => [...html.matchAll(/fila (\w+)"><span>([^<]+)</g)].map((m) => `${m[1]}:${m[2]}`);
    assert.deepEqual(nombres(tablero.vistaHost(h, 0)), ["aviso:HDD sda", "ok:SSD sdb", "ok:Raíz", "critico:NAS"], "densidad 0: todas, en su orden");
    const d1 = tablero.vistaHost(h, 1);
    assert.deepEqual(nombres(d1), ["aviso:HDD sda", "critico:NAS", "ok:En orden"], "densidad 1: los avisos primero");
    assert.match(d1, /<span class="ok"><small>SSD sdb<\/small>43 °C<\/span><span class="ok"><small>Raíz<\/small>86 % libre<\/span>/);
    const d2 = tablero.vistaHost(h, 2);
    assert.match(d2, /En orden<\/span><b><span class="lista"><span class="ok">SSD sdb<\/span><span class="ok">Raíz<\/span><\/span>/, "densidad 2: solo nombres");
    for (let d = 0; d < tablero.DENSIDADES; d++) {
        const html = tablero.vistaHost(h, d);
        assert.match(html, /fila critico"><span>NAS<\/span><b>2,0 % libre/, `el NAS en rojo y con su cifra en la densidad ${d}`);
        assert.match(html, /fila aviso"><span>HDD sda<\/span><b>16 pendientes/, `el HDD con su detalle en la densidad ${d}`);
    }
    assert.ok(!/En orden/.test(tablero.vistaHost({ discos: [{ disco: "sda", lectura_ok: 0 }] }, 2)), "sin nada sano no hay fila «En orden»");
});

test("tablero: la frescura de Thor va en el título de Host", () => {
    assert.equal(tablero.frescuraHost({ thor_hace_s: 30 }), null);
    assert.deepEqual(tablero.frescuraHost({ thor_hace_s: 720 }), { nivel: "aviso", texto: "datos de hace 12 min" });
    assert.deepEqual(tablero.frescuraHost({}), { nivel: "nodato", texto: "sin datos de Thor" });
    assert.ok(!/Thor/.test(tablero.vistaHost({ thor_hace_s: 720, discos: [] }, 0)), "ya no es una fila");
});

test("tablero: el pie de Host nombra lo que no cabe, con el color del peor", () => {
    assert.equal(tablero.vistaOcultas([]), null);
    assert.deepEqual(tablero.vistaOcultas([{ nombre: "En orden", nivel: "ok" }]), { nivel: "ok", texto: "Sin sitio para 1 fila: En orden" });
    assert.deepEqual(tablero.vistaOcultas([{ nombre: "NAS", nivel: "aviso" }, { nombre: "SSD sdb", nivel: "critico" }, { nombre: "En orden", nivel: "ok" }]),
        { nivel: "critico", texto: "Sin sitio para 3 filas: NAS · SSD sdb · En orden" });
});

test("tablero: la batería de la tablet, también cuando dice que carga y no carga", () => {
    assert.equal(tablero.vistaBateria(0.8, true, false), null, "enchufada y cargando: nada que decir");
    assert.equal(tablero.vistaBateria(null, false, false), null, "sin API de batería: nada");
    assert.deepEqual(tablero.vistaBateria(0.62, false, false), { nivel: "aviso", texto: "Tablet sin cargar · 62 %" });
    assert.deepEqual(tablero.vistaBateria(0.1, false, false), { nivel: "critico", texto: "Tablet sin cargar · 10 %" });
    // 2026-10-19: con el USB del PC el WebView decía charging=true y la batería bajaba
    assert.deepEqual(tablero.vistaBateria(0.6, true, true), { nivel: "aviso", texto: "Tablet pierde carga enchufada · 60 %" });
    assert.deepEqual(tablero.vistaBateria(0.16, true, false), { nivel: "aviso", texto: "Tablet al 16 %" });
});

test("tablero: el texto del servidor se escapa (una anotación no puede inyectar HTML)", () => {
    const html = tablero.vistaAlertas([{ nombre: "<img src=x onerror=alert(1)>", severidad: "warning", resumen: "NAS <b>lleno</b>", desde: "2026-10-16T10:00:00Z" }], AHORA, true);
    assert.ok(!html.includes("<img"));
    assert.ok(html.includes("&lt;img src=x onerror=alert(1)&gt;"));
    assert.ok(html.includes("NAS &lt;b&gt;lleno&lt;/b&gt;"));
    assert.match(tablero.vistaAlertas([], AHORA, false), /Gjallarhorn no responde/);
});

test("tablero: como mucho tres alertas, y las demás en una línea con su nombre", () => {
    const alerta = (n) => ({ nombre: `A${n}`, severidad: "warning", resumen: "x", desde: "2026-10-19T10:00:00Z" });
    const cinco = tablero.vistaAlertas([1, 2, 3, 4, 5].map(alerta), AHORA, true);
    assert.equal((cinco.match(/<li class="aviso">/g) || []).length, 3);
    assert.match(cinco, /<b>A3</);
    assert.ok(!cinco.includes("<b>A4<"));
    assert.match(cinco, /<li class="mas">y 2 alertas más: <span class="aviso">A4<\/span> · <span class="aviso">A5<\/span><\/li>/);
    assert.match(tablero.vistaAlertas([1, 2, 3, 4].map(alerta), AHORA, true), /y 1 alerta más: <span class="aviso">A4</);
    const compactas = tablero.vistaAlertas([1, 2].map(alerta), AHORA, true, true);
    assert.equal((compactas.match(/<li class="aviso compacta">/g) || []).length, 2, "compactas: una línea por alerta");
    assert.ok(!compactas.includes("<span>x</span>"), "compactas: sin el resumen");
    assert.ok(!/class="mas"/.test(tablero.vistaAlertas([1, 2, 3].map(alerta), AHORA, true)));
});

test("tablero: las unidades del host en orden se resumen; los contenedores y las caídas, con nombre", () => {
    const html = tablero.vistaServicios([
        { tipo: "contenedor", nombre: "yggdrasil-prometheus", ok: 1 },
        { tipo: "unidad", nombre: "dnsmasq.service", ok: 1 },
        { tipo: "unidad", nombre: "respaldo.timer", ok: 1 },
        { tipo: "unidad", nombre: "wan-watchdog.timer", ok: 0 },
    ]);
    assert.match(html, /Mimir<small>prometheus<\/small>/);
    assert.match(html, /servicio critico.*>wan-watchdog<small>temporizador<\/small>/);
    assert.ok(!html.includes(">dnsmasq<"), "una unidad en orden no lleva ficha propia");
    assert.match(html, /servicio resumen ok"><i><\/i>2 unidades del host en orden</);
    assert.ok(!/resumen/.test(tablero.vistaServicios([{ tipo: "unidad", nombre: "x.service", ok: 0 }])), "sin unidades en orden no hay ficha resumen");
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

test("tablero: la tarjeta de una WAN caída dice desde cuándo, no 0 ms ni velocidades vacías", () => {
    const desde = new Date((AHORA - 6 * 3600 - 60) * 1000).toISOString();
    const alertas = [{ nombre: "WanCaida", wan: "wan2", severidad: "critical", desde }, { nombre: "WanCaida", wan: "wan1", desde: "2026-01-01T00:00:00Z" }];
    const html = tablero.vistaWan({ wan: "wan2", up: 0, en_ruta: 1, latencia_p95_ms: 0, subida_mbps: null }, alertas, AHORA);
    assert.match(html, /tarjeta wan critico/);
    assert.match(html, /CAÍDA/);
    assert.match(html, /chip critico">en la ruta/);
    assert.match(html, /<b>—<small> ms<\/small><\/b>/, "latencia «—», no el 0 que da Mimir");
    assert.match(html, /velocidades caida"><b>Caída hace 6 h<\/b><small class="medido">desde las \d\d:\d\d<\/small>/);
    assert.ok(!/vel /.test(html), "sin velocidades");
    assert.match(tablero.vistaWan({ wan: "wan2", up: 0 }, [], AHORA), /<b>Sin servicio<\/b>/, "sin su WanCaida no inventa la hora");
    // en línea, las velocidades con su SLO como siempre
    assert.match(tablero.vistaWan({ wan: "wan2", up: 1, en_ruta: 1, subida_mbps: 102, slo_subida_mbps: 400 }, [], AHORA), /vel aviso">↑ 102<small> \/ 400 Mbps/);
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
