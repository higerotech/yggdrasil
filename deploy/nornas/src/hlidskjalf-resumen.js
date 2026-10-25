// Nodo function "Resumen de midgard" del tablero Hlidskjalf: una consulta instantánea a Mimir con
// todas las series que pinta la tablet y la lista de alertas activas de Gjallarhorn, convertidas
// en un JSON pequeño. La tablet (Galaxy Tab 2, 1 GB de RAM) no habla PromQL ni carga Grafana:
// recibe solo lo que dibuja. Si una fuente no responde, su sección va vacía y `fuentes` lo dice;
// el tablero lo muestra en vez de dar por buena una pantalla en verde.
//
// Thor corre también en otros hosts (nidavellir): sus series llevan la etiqueta `host` y las de
// midgard no. `host` y `servicios` son de midgard, como siempre; cada otro host va en `hosts`, con
// sus discos, volúmenes y servicios aparte (los dos tienen un sda).
const consultar = global.get("consultarJson");
const MIMIR = env.get("HLIDSKJALF_MIMIR_URL") || "http://mimir:9090";
const GJALLARHORN = env.get("HLIDSKJALF_GJALLARHORN_URL") || "http://gjallarhorn:9093";

const SERIES = [
    "wan:up", "wan:perdida_pct:5m", "wan:latencia_p95:5m", "wan:disponibilidad:30d", "wan:slo_throughput_mbps",
    "hogar:up", "hogar:disponibilidad:30d",
    "wan_throughput_mbps", "wan_throughput_ultima_medicion_timestamp_seconds", "wan_throughput_medicion_en_curso",
    "yggdrasil_wan_en_ruta", "yggdrasil_thor_timestamp_seconds",
    "yggdrasil_smart_atributo", "yggdrasil_smart_salud", "yggdrasil_smart_lectura_ok",
    "yggdrasil_fs_montado", "yggdrasil_fs_tamano_bytes", "yggdrasil_fs_libre_bytes",
    "yggdrasil_disco_rotacional", "yggdrasil_disco_errores_kernel_15m",
    "yggdrasil_servicio_ok", "yggdrasil_respaldo_ultimo_exito_timestamp_seconds",
    "yggdrasil_arranque_timestamp_seconds", "yggdrasil_cpu_temperatura_celsius",
];
// Atributos SMART que enseña el tablero (los que publica Thor y vigila DiscoEmpeora, más contexto).
const SMART = { 5: "reasignados", 187: "no_corregidos", 197: "pendientes", 198: "incorregibles", 199: "errores_cable", 194: "temperatura_c", 9: "horas" };
const GRAVEDAD = { critical: 0, warning: 1, info: 2 };

// `up` de Thor: un host colgado no tiene series (caducan a los 5 min), pero su `up` sigue, a 0.
// `or` compara las etiquetas sin el nombre: `up{instance,job}` coincide con
// `yggdrasil_thor_timestamp_seconds{instance,job}` y se descartaba justo con el host en marcha (0.5.17).
// La etiqueta `serie` lo hace distinto.
const consulta = `{__name__=~"${SERIES.join("|")}"} or label_replace(up{job="thor"}, "serie", "up", "", "")`;
const [prom, am] = await Promise.allSettled([
    consultar(`${MIMIR}/api/v1/query?query=${encodeURIComponent(consulta)}`, 5000),
    consultar(`${GJALLARHORN}/api/v2/alerts?active=true&silenced=false&inhibited=false`, 5000),
]);

const ahora = Math.round(Date.now() / 1000);
const mimirOk = prom.status === "fulfilled" && prom.value && prom.value.status === "success";
const series = mimirOk ? prom.value.data.result : [];
const num = (v) => { const n = Number(v); return Number.isFinite(n) ? n : null; };
// `host` del filtro: el de la serie, o "" para las de midgard, que no lo llevan.
const de = (nombre, filtro = {}) => series.filter((s) => s.metric.__name__ === nombre &&
    (s.metric.host || "") === (filtro.host || "") &&
    Object.entries(filtro).every(([k, v]) => k === "host" || s.metric[k] === v));
const valor = (nombre, filtro) => { const s = de(nombre, filtro)[0]; return s ? num(s.value[1]) : null; };
const hace = (ts) => (ts === null ? null : Math.max(0, ahora - ts));

const wans = [...new Set(series.filter((s) => s.metric.wan && /^wan[0-9]+$/.test(s.metric.wan)).map((s) => s.metric.wan))].sort();
const wan = wans.map((w) => {
    const latencia = valor("wan:latencia_p95:5m", { wan: w });
    return {
        wan: w,
        up: valor("wan:up", { wan: w }),
        en_ruta: valor("yggdrasil_wan_en_ruta", { wan: w }),
        perdida_pct: valor("wan:perdida_pct:5m", { wan: w }),
        latencia_p95_ms: latencia === null ? null : Math.round(latencia * 10000) / 10,
        disponibilidad_30d: valor("wan:disponibilidad:30d", { wan: w }),
        bajada_mbps: valor("wan_throughput_mbps", { wan: w, direccion: "down" }),
        subida_mbps: valor("wan_throughput_mbps", { wan: w, direccion: "up" }),
        slo_bajada_mbps: valor("wan:slo_throughput_mbps", { wan: w, direccion: "down" }),
        slo_subida_mbps: valor("wan:slo_throughput_mbps", { wan: w, direccion: "up" }),
        medicion_hace_s: hace(valor("wan_throughput_ultima_medicion_timestamp_seconds", { wan: w })),
        sleipnir_midiendo: valor("wan_throughput_medicion_en_curso", { wan: w }),
    };
});

const discosDe = (host) => [...new Set(de("yggdrasil_smart_lectura_ok", { host }).map((s) => s.metric.disco))].sort().map((d) => {
    const f = { host, disco: d };
    const disco = { disco: d, lectura_ok: valor("yggdrasil_smart_lectura_ok", f), salud: valor("yggdrasil_smart_salud", f) };
    for (const [id, clave] of Object.entries(SMART)) disco[clave] = valor("yggdrasil_smart_atributo", { ...f, id });
    disco.rotacional = valor("yggdrasil_disco_rotacional", f);
    disco.errores_kernel = valor("yggdrasil_disco_errores_kernel_15m", f);
    return disco;
});
const fsDe = (host) => de("yggdrasil_fs_montado", { host }).map((s) => s.metric.punto).sort().map((p) => ({
    punto: p,
    montado: valor("yggdrasil_fs_montado", { host, punto: p }),
    tamano_bytes: valor("yggdrasil_fs_tamano_bytes", { host, punto: p }),
    libre_bytes: valor("yggdrasil_fs_libre_bytes", { host, punto: p }),
}));
const serviciosDe = (host) => de("yggdrasil_servicio_ok", { host })
    .map((s) => ({ tipo: s.metric.tipo, nombre: s.metric.nombre, ok: num(s.value[1]) }))
    .sort((a, b) => (a.tipo === b.tipo ? a.nombre.localeCompare(b.nombre) : a.tipo === "contenedor" ? -1 : 1));
const temperatura = (host) => { const t = valor("yggdrasil_cpu_temperatura_celsius", { host }); return t === null ? null : Math.round(t); };
const discos = discosDe("");
const fs = fsDe("");
// Un respaldo por etiqueta `respaldo` (Yggdrasil, Bifrost...). Sin etiqueta es el de Yggdrasil:
// así lo publicaba Thor antes de admitir varios.
const respaldos = de("yggdrasil_respaldo_ultimo_exito_timestamp_seconds")
    .map((s) => {
        const ts = num(s.value[1]);
        return { nombre: s.metric.respaldo || "yggdrasil", ultimo_exito: ts, hace_h: ts === null ? null : Math.floor(hace(ts) / 3600) };
    })
    .sort((a, b) => (a.nombre === "yggdrasil" ? -1 : b.nombre === "yggdrasil" ? 1 : a.nombre.localeCompare(b.nombre)));
const respaldo = respaldos.find((r) => r.nombre === "yggdrasil") || { ultimo_exito: null, hace_h: null };
const servicios = serviciosDe("");
// Los otros hosts, por su `up` de Thor: sigue ahí (a 0) aunque el host esté colgado.
const hosts = [...new Set(series.filter((s) => s.metric.__name__ === "up" && s.metric.host).map((s) => s.metric.host))].sort().map((h) => ({
    nombre: h,
    up: valor("up", { host: h }),
    thor_hace_s: hace(valor("yggdrasil_thor_timestamp_seconds", { host: h })),
    arranque_hace_s: hace(valor("yggdrasil_arranque_timestamp_seconds", { host: h })),
    cpu_temperatura_c: temperatura(h),
    discos: discosDe(h),
    fs: fsDe(h),
    servicios: serviciosDe(h),
}));

const amOk = am.status === "fulfilled" && Array.isArray(am.value);
const alertas = (amOk ? am.value : [])
    .map((a) => ({
        nombre: a.labels.alertname,
        severidad: a.labels.severity || "warning",
        wan: a.labels.wan || null,
        resumen: (a.annotations && a.annotations.resumen) || a.labels.alertname,
        desde: a.startsAt,
    }))
    .sort((a, b) => ((GRAVEDAD[a.severidad] ?? 1) - (GRAVEDAD[b.severidad] ?? 1)) || String(a.desde).localeCompare(String(b.desde)));

msg.payload = {
    version: 1,
    generado: ahora,
    fuentes: { mimir: mimirOk, gjallarhorn: amOk },
    hogar: { up: valor("hogar:up"), disponibilidad_30d: valor("hogar:disponibilidad:30d") },
    wan,
    alertas,
    host: {
        thor_hace_s: hace(valor("yggdrasil_thor_timestamp_seconds")),
        arranque_hace_s: hace(valor("yggdrasil_arranque_timestamp_seconds")),
        cpu_temperatura_c: temperatura(""),
        discos,
        fs,
        // `respaldo` (solo el de Yggdrasil) queda para la tablet que aún tenga cargado el tablero viejo
        respaldo: { ultimo_exito: respaldo.ultimo_exito, hace_h: respaldo.hace_h },
        respaldos,
    },
    servicios,
    hosts,
};
// Un aviso por cambio de estado de cada fuente, no uno por consulta (la tablet pide cada 15 s).
const antes = context.get("fuentes") || { mimir: true, gjallarhorn: true };
const motivo = (r, otro) => (r.status === "rejected" ? r.reason.message : otro);
if (antes.mimir !== mimirOk) node.warn(mimirOk ? "Hlidskjalf: Mimir responde de nuevo" : `Hlidskjalf: Mimir no respondió (${motivo(prom, "respuesta sin datos")})`);
if (antes.gjallarhorn !== amOk) node.warn(amOk ? "Hlidskjalf: Gjallarhorn responde de nuevo" : `Hlidskjalf: Gjallarhorn no respondió (${motivo(am, "respuesta inesperada")})`);
context.set("fuentes", { mimir: mimirOk, gjallarhorn: amOk });
msg.statusCode = 200;
msg.headers = { "Cache-Control": "no-store" };
return msg;
