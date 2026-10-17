/* Hlidskjalf — tablero de pared de midgard.
 *
 * Pide /hlidskjalf/resumen a Nornas cada 15 s y pinta cuatro bloques: WAN, alertas activas, salud
 * del host y servicios. Escrito para el WebView de la Galaxy Tab 2 (Chromium 81, 1 GB de RAM):
 * sin framework ni dependencias, todo el HTML sale de funciones puras que también se prueban
 * en Node (tests/hlidskjalf.test.mjs), y todo texto que viene del servidor pasa por esc().
 *
 * El token de lectura llega una vez en el fragmento (#t=...), que el navegador no envía al
 * servidor; se guarda en localStorage y se quita de la barra de direcciones.
 */
(function () {
    "use strict";

    var CADA_MS = 15000;
    var LIMITE_MS = 10000;
    var CLAVE_TOKEN = "hlidskjalf.token";

    // container_name → nombre nórdico (docs/00-project/naming.md)
    var NORDICOS = {
        "yggdrasil-blackbox-exporter": "Huginn y Muninn",
        "yggdrasil-throughput-probe": "Sleipnir",
        "yggdrasil-prometheus": "Mimir",
        "yggdrasil-alertmanager": "Gjallarhorn",
        "yggdrasil-grafana": "Odín",
        "yggdrasil-mosquitto": "Ratatosk",
        "yggdrasil-node-red": "Nornas",
        "yggdrasil-host-metrics": "Thor"
    };

    function esc(v) {
        return String(v === null || v === undefined ? "" : v).replace(/[&<>"']/g, function (c) {
            return { "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;" }[c];
        });
    }
    function hay(v) { return v !== null && v !== undefined; }
    function numero(v, decimales) {
        if (!hay(v)) return "—";
        var d = decimales || 0;
        return new Intl.NumberFormat("es-ES", { minimumFractionDigits: d, maximumFractionDigits: d, useGrouping: true }).format(v);
    }
    function porcentaje(ratio, decimales) { return hay(ratio) ? numero(ratio * 100, decimales) + " %" : "—"; }
    function bytes(v) {
        if (!hay(v)) return "—";
        var tb = 1e12, gb = 1e9;
        return v >= tb ? numero(v / tb, 2) + " TB" : numero(v / gb, 1) + " GB";
    }
    function duracion(s) {
        if (!hay(s)) return "—";
        if (s < 60) return Math.round(s) + " s";
        if (s < 3600) return Math.floor(s / 60) + " min";
        if (s < 172800) return Math.floor(s / 3600) + " h";
        return Math.floor(s / 86400) + " d";
    }
    function sinPrefijo(nombre) { return String(nombre).replace(/^yggdrasil-/, ""); }

    // --- Niveles -----------------------------------------------------------------------------
    // Sleipnir satura el enlace unos 70 s al medir la velocidad: las sondas ICMP ven pérdida y la
    // latencia sube, y no es una avería. La ventana de 5 min de wan:perdida_pct:5m la arrastra hasta
    // 5 min después de terminar; 30 s más cubren la evaluación de la regla y el sondeo de la tablet.
    var TRAS_MEDICION_S = 330;
    function enMedicion(w) {
        return w.sleipnir_midiendo === 1 || (hay(w.medicion_hace_s) && w.medicion_hace_s < TRAS_MEDICION_S);
    }
    function nivelWan(w) {
        if (!hay(w.up)) return "nodato";
        if (w.up === 0) return "critico";
        if (w.en_ruta === 0) return "aviso";                       // sana pero fuera de la ruta
        if (enMedicion(w)) return "ok";                           // la caída la sigue decidiendo wan:up
        if ((hay(w.perdida_pct) && w.perdida_pct >= 1) || (hay(w.latencia_p95_ms) && w.latencia_p95_ms >= 200)) return "aviso";
        return "ok";
    }
    function nivelVelocidad(medido, slo) {
        if (!hay(medido) || !hay(slo)) return "nodato";
        return medido < slo ? "aviso" : "ok";
    }
    function nivelDisco(d) {
        if (d.lectura_ok === 0) return "aviso";
        if (d.salud === 0) return "critico";
        if ((d.pendientes || 0) > 0 || (d.incorregibles || 0) > 0 || (d.reasignados || 0) > 0) return "aviso";
        return "ok";
    }
    function libreRatio(f) { return hay(f.libre_bytes) && f.tamano_bytes ? f.libre_bytes / f.tamano_bytes : null; }
    function nivelFs(f) {
        if (f.montado === 0) return "critico";
        var r = libreRatio(f);
        if (!hay(r)) return "nodato";
        return r < 0.03 ? "critico" : r < 0.10 ? "aviso" : "ok";
    }
    function nivelRespaldo(r) {
        if (!r || !hay(r.hace_h)) return "aviso";
        return r.hace_h >= 26 ? "aviso" : "ok";
    }
    function nivelAlerta(a) { return a.severidad === "critical" ? "critico" : a.severidad === "info" ? "ok" : "aviso"; }

    // Estado de la cabecera: el peor de todo lo que se ve, con una frase que lo explique.
    function estadoGeneral(r) {
        var caidos = (r.servicios || []).filter(function (s) { return s.ok === 0; });
        var alertas = (r.alertas || []).filter(function (a) { return a.severidad !== "info"; });
        var criticas = alertas.filter(function (a) { return a.severidad === "critical"; });
        if (r.hogar && r.hogar.up === 0) return { nivel: "critico", texto: "Midgard sin internet" };
        if (!r.fuentes || !r.fuentes.mimir) return { nivel: "aviso", texto: "Sin datos de Mimir" };
        if (criticas.length) return { nivel: "critico", texto: criticas.length === 1 ? "1 alerta crítica" : criticas.length + " alertas críticas" };
        if (caidos.length) return { nivel: "critico", texto: caidos.length === 1 ? "1 servicio caído" : caidos.length + " servicios caídos" };
        if (alertas.length) return { nivel: "aviso", texto: alertas.length === 1 ? "1 alerta activa" : alertas.length + " alertas activas" };
        if (!r.fuentes.gjallarhorn) return { nivel: "aviso", texto: "Sin datos de Gjallarhorn" };
        return { nivel: "ok", texto: "Todo en orden" };
    }

    // --- Vistas (HTML) -----------------------------------------------------------------------
    var ETIQUETA_WAN = { ok: "EN LÍNEA", aviso: "EN LÍNEA", critico: "CAÍDA", nodato: "SIN DATOS" };

    function velocidad(flecha, medido, slo) {
        return "<span class=\"vel " + nivelVelocidad(medido, slo) + "\">" + flecha + " " + numero(medido) +
            "<small> / " + numero(slo) + " Mbps</small></span>";
    }
    function vistaWan(w) {
        var n = nivelWan(w);
        var ruta = !hay(w.en_ruta) ? "" : w.en_ruta === 1
            ? "<span class=\"chip " + (w.up === 0 ? "critico" : "ok") + "\">en la ruta</span>"
            : "<span class=\"chip " + (w.up === 1 ? "aviso" : "nodato") + "\">fuera de la ruta</span>";
        var medicion = !enMedicion(w) ? "" : "<span class=\"chip medicion\">" +
            (w.sleipnir_midiendo === 1 ? "Sleipnir midiendo" : "tras medir la velocidad") + "</span>";
        return "<section class=\"tarjeta wan " + n + "\">" +
            "<header><h2>" + esc(w.wan) + "</h2><span class=\"estado " + n + "\">" + ETIQUETA_WAN[n] + "</span>" + medicion + ruta + "</header>" +
            "<div class=\"cifras\">" +
            "<div><small>latencia p95</small><b>" + numero(w.latencia_p95_ms, w.latencia_p95_ms < 10 ? 1 : 0) + "<small> ms</small></b></div>" +
            "<div><small>pérdida</small><b>" + numero(w.perdida_pct, 1) + "<small> %</small></b></div>" +
            "<div><small>30 días</small><b>" + porcentaje(w.disponibilidad_30d, 1) + "</b></div>" +
            "</div>" +
            "<div class=\"velocidades\">" + velocidad("↓", w.bajada_mbps, w.slo_bajada_mbps) + velocidad("↑", w.subida_mbps, w.slo_subida_mbps) +
            "<small class=\"medido\">medido hace " + duracion(w.medicion_hace_s) + "</small></div>" +
            "</section>";
    }
    function vistaHogar(h) {
        var n = !h || !hay(h.up) ? "nodato" : h.up === 1 ? "ok" : "critico";
        return "<div class=\"hogar " + n + "\">Hogar con internet: <b>" + (n === "ok" ? "sí" : n === "critico" ? "NO" : "—") +
            "</b> · 30 días " + porcentaje(h && h.disponibilidad_30d, 2) + "</div>";
    }
    function vistaAlertas(lista, ahora, fuenteOk) {
        if (!fuenteOk) return "<p class=\"vacio aviso\">Gjallarhorn no responde: no se sabe qué alertas hay.</p>";
        if (!lista.length) return "<p class=\"vacio ok\">Sin alertas activas</p>";
        return "<ul class=\"alertas\">" + lista.map(function (a) {
            var desde = Date.parse(a.desde);
            var t = isNaN(desde) ? "" : duracion(ahora - desde / 1000);
            return "<li class=\"" + nivelAlerta(a) + "\"><span class=\"punto\"></span><div><b>" + esc(a.nombre) +
                (a.wan ? " <small>" + esc(a.wan) + "</small>" : "") + "</b><span>" + esc(a.resumen) + "</span></div>" +
                "<time>" + esc(t) + "</time></li>";
        }).join("") + "</ul>";
    }
    function fila(nivel, nombre, valor) {
        return "<div class=\"fila " + nivel + "\"><span>" + nombre + "</span><b>" + valor + "</b></div>";
    }
    function vistaHost(h) {
        var partes = [];
        (h.discos || []).forEach(function (d) {
            var detalle = d.lectura_ok === 0 ? "sin lectura SMART"
                : (d.salud === 0 ? "SMART FALLA · " : "") + numero(d.pendientes) + " pendientes · " + numero(d.incorregibles) +
                  " incorregibles · " + numero(d.reasignados) + " reasignados" + (hay(d.temperatura_c) ? " · " + numero(d.temperatura_c) + " °C" : "");
            partes.push(fila(nivelDisco(d), "Disco " + esc(d.disco), detalle));
        });
        (h.fs || []).forEach(function (f) {
            var nombre = f.punto === "/" ? "Raíz" : /nas/.test(f.punto) ? "NAS" : esc(f.punto);
            var r = libreRatio(f);
            var valor = f.montado === 0 ? "NO MONTADO"
                : porcentaje(r, 1) + " libre <small>(" + bytes(f.libre_bytes) + " de " + bytes(f.tamano_bytes) + ")</small>";
            // <progress> y no un atributo de estilo: la CSP no admite estilos en línea
            var barra = hay(r) ? "<progress class=\"barra\" max=\"100\" value=\"" + Math.max(0, Math.min(100, (1 - r) * 100)).toFixed(1) + "\"></progress>" : "";
            partes.push(fila(nivelFs(f), nombre, valor + barra));
        });
        var rsp = h.respaldo || {};
        partes.push(fila(nivelRespaldo(rsp), "Respaldo", hay(rsp.hace_h) ? "hace " + duracion(rsp.hace_h * 3600) : "sin constancia"));
        if (hay(h.thor_hace_s) && h.thor_hace_s > 300) partes.push(fila("aviso", "Thor", "datos de hace " + duracion(h.thor_hace_s)));
        if (!hay(h.thor_hace_s)) partes.push(fila("nodato", "Thor", "sin datos del host"));
        return partes.join("");
    }
    function vistaServicios(lista) {
        if (!lista.length) return "<p class=\"vacio nodato\">Sin datos de servicios</p>";
        return lista.map(function (s) {
            var n = s.ok === 1 ? "ok" : "critico";
            var nombre = s.tipo === "contenedor" ? (NORDICOS[s.nombre] || sinPrefijo(s.nombre)) : sinPrefijo(s.nombre).replace(/\.(service|timer)$/, "");
            var tecnico = s.tipo === "contenedor" ? sinPrefijo(s.nombre) : (/\.timer$/.test(s.nombre) ? "temporizador" : "unidad");
            return "<span class=\"servicio " + n + "\" title=\"" + esc(s.nombre) + "\"><i></i>" + esc(nombre) +
                "<small>" + esc(tecnico) + "</small></span>";
        }).join("");
    }
    function vistaTodo(r) {
        var e = estadoGeneral(r);
        return {
            estado: e,
            wan: (r.wan || []).map(vistaWan).join("") + vistaHogar(r.hogar),
            alertas: vistaAlertas(r.alertas || [], r.generado, r.fuentes && r.fuentes.gjallarhorn),
            nAlertas: (r.alertas || []).length,
            host: vistaHost(r.host || {}),
            servicios: vistaServicios(r.servicios || [])
        };
    }

    // --- Navegador ---------------------------------------------------------------------------
    function iniciar() {
        var $ = function (id) { return document.getElementById(id); };
        var ultimoOk = null, error = null;

        function leerToken() {
            var m = /(?:^#|&)t=([^&]+)/.exec(location.hash);
            try {
                if (m) {
                    localStorage.setItem(CLAVE_TOKEN, decodeURIComponent(m[1]));
                    history.replaceState(null, "", location.pathname + location.search);
                }
                return localStorage.getItem(CLAVE_TOKEN);
            } catch (e) {
                return m ? decodeURIComponent(m[1]) : null;
            }
        }
        var token = leerToken();

        function pintarEstado() {
            var cab = $("cabecera");
            var reloj = new Date().toLocaleTimeString("es-VE", { hour: "2-digit", minute: "2-digit", hour12: false });
            $("reloj").textContent = reloj;
            if (error) {
                cab.className = "cabecera critico";
                $("estado").textContent = error;
            }
            var t = ultimoOk ? (Date.now() - ultimoOk) / 1000 : null;
            $("frescura").textContent = t === null ? "sin datos" : "actualizado hace " + duracion(t);
            document.body.classList.toggle("viejo", t !== null && t > 60);
        }

        function pintar(r) {
            var v = vistaTodo(r);
            $("cabecera").className = "cabecera " + v.estado.nivel;
            $("estado").textContent = v.estado.texto;
            $("wan").innerHTML = v.wan;
            $("alertas").innerHTML = v.alertas;
            $("n-alertas").textContent = v.nAlertas ? "(" + v.nAlertas + ")" : "";
            $("host").innerHTML = v.host;
            $("servicios").innerHTML = v.servicios;
        }

        function pedir() {
            if (!token) {
                error = "Falta el token: abre /hlidskjalf/#t=<HLIDSKJALF_TOKEN>";
                pintarEstado();
                return;
            }
            var ctl = typeof AbortController === "function" ? new AbortController() : null;
            var limite = setTimeout(function () { if (ctl) ctl.abort(); }, LIMITE_MS);
            fetch("/hlidskjalf/resumen", { headers: { Authorization: "Bearer " + token }, cache: "no-store", signal: ctl ? ctl.signal : undefined })
                .then(function (res) {
                    if (res.status === 401) throw new Error("Token rechazado por Nornas");
                    if (!res.ok) return res.json().then(function (j) { throw new Error(j.error || "HTTP " + res.status); },
                        function () { throw new Error("Nornas respondió HTTP " + res.status); });
                    return res.json();
                })
                .then(function (r) { error = null; ultimoOk = Date.now(); pintar(r); })
                .catch(function (e) {
                    error = e.name === "AbortError" || e instanceof TypeError ? "Sin conexión con midgard" : e.message;
                })
                .then(function () { clearTimeout(limite); pintarEstado(); setTimeout(pedir, CADA_MS); });
        }

        setInterval(pintarEstado, 1000);
        pedir();
    }

    var api = {
        esc: esc, numero: numero, porcentaje: porcentaje, bytes: bytes, duracion: duracion,
        enMedicion: enMedicion, nivelWan: nivelWan, nivelDisco: nivelDisco, nivelFs: nivelFs, nivelRespaldo: nivelRespaldo,
        estadoGeneral: estadoGeneral, vistaWan: vistaWan, vistaAlertas: vistaAlertas, vistaHost: vistaHost,
        vistaServicios: vistaServicios, vistaTodo: vistaTodo
    };
    if (typeof module === "object" && module.exports) {
        module.exports = api;
    } else {
        iniciar();
    }
})();
