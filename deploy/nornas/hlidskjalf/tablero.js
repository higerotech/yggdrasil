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
    var PUNTOS = { "/": "Raíz", "/srv/rapido": "SSD" };
    var RESPALDOS = { yggdrasil: "Yggdrasil", bifrost: "Bifröst", hermod: "Hermod", andvari: "Andvari" };

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
        // Antes que SMART: un disco que se cae del bus puede tener SMART limpio (el SSD, 2026-10-19)
        if ((d.errores_kernel || 0) > 0) return "critico";
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
    function hora(ms, ahoraMs) {
        var d = new Date(ms);
        var hm = d.toLocaleTimeString("es-VE", { hour: "2-digit", minute: "2-digit", hour12: false });
        return ahoraMs - ms < 86400000 ? hm : d.toLocaleDateString("es-VE", { day: "2-digit", month: "2-digit" }) + " " + hm;
    }
    // Con la WAN caída, latencia y velocidades no dicen nada (Mimir da 0 ms y la última medición
    // falló): el pie de la tarjeta cuenta desde cuándo está caída, con la hora de su WanCaida.
    function pieCaida(w, alertas, ahora) {
        var a = (alertas || []).filter(function (x) { return x.nombre === "WanCaida" && x.wan === w.wan; })[0];
        var desde = a ? Date.parse(a.desde) : NaN;
        if (isNaN(desde)) return "<div class=\"velocidades caida\"><b>Sin servicio</b><small class=\"medido\">Gjallarhorn no da la hora de inicio</small></div>";
        return "<div class=\"velocidades caida\"><b>Caída hace " + duracion(ahora - desde / 1000) + "</b>" +
            "<small class=\"medido\">desde las " + hora(desde, ahora * 1000) + "</small></div>";
    }
    function vistaWan(w, alertas, ahora) {
        var n = nivelWan(w);
        var caida = w.up === 0;
        var ruta = !hay(w.en_ruta) ? "" : w.en_ruta === 1
            ? "<span class=\"chip " + (w.up === 0 ? "critico" : "ok") + "\">en la ruta</span>"
            : "<span class=\"chip " + (w.up === 1 ? "aviso" : "nodato") + "\">fuera de la ruta</span>";
        var medicion = !enMedicion(w) ? "" : "<span class=\"chip medicion\">" +
            (w.sleipnir_midiendo === 1 ? "Sleipnir midiendo" : "tras medir la velocidad") + "</span>";
        return "<section class=\"tarjeta wan " + n + "\">" +
            "<header><h2>" + esc(w.wan) + "</h2><span class=\"estado " + n + "\">" + ETIQUETA_WAN[n] + "</span>" + medicion + ruta + "</header>" +
            "<div class=\"cifras\">" +
            "<div><small>latencia p95</small><b>" + (caida ? "—" : numero(w.latencia_p95_ms, w.latencia_p95_ms < 10 ? 1 : 0)) + "<small> ms</small></b></div>" +
            "<div><small>pérdida</small><b>" + (caida ? "—" : numero(w.perdida_pct, 1)) + "<small> %</small></b></div>" +
            "<div><small>30 días</small><b>" + porcentaje(w.disponibilidad_30d, 1) + "</b></div>" +
            "</div>" +
            (caida ? pieCaida(w, alertas, ahora) :
                "<div class=\"velocidades\">" + velocidad("↓", w.bajada_mbps, w.slo_bajada_mbps) + velocidad("↑", w.subida_mbps, w.slo_subida_mbps) +
                "<small class=\"medido\">medido hace " + duracion(w.medicion_hace_s) + "</small></div>") +
            "</section>";
    }
    function vistaHogar(h) {
        var n = !h || !hay(h.up) ? "nodato" : h.up === 1 ? "ok" : "critico";
        return "<div class=\"hogar " + n + "\">Hogar con internet: <b>" + (n === "ok" ? "sí" : n === "critico" ? "NO" : "—") +
            "</b> · 30 días " + porcentaje(h && h.disponibilidad_30d, 2) + "</div>";
    }
    // Más de tres alertas empujarían Host fuera de la pantalla: las demás se resumen en una línea.
    // El resumen ya las trae ordenadas de la más grave a la menos.
    var MAX_ALERTAS = 3;
    // compactas: una línea por alerta, sin el resumen. Es el penúltimo recurso para que Host quepa
    // (ver ajustarDerecha): el detalle de las alertas del host ya está en sus filas.
    function vistaAlertas(lista, ahora, fuenteOk, compactas) {
        if (!fuenteOk) return "<p class=\"vacio aviso\">Gjallarhorn no responde: no se sabe qué alertas hay.</p>";
        if (!lista.length) return "<p class=\"vacio ok\">Sin alertas activas</p>";
        var resto = lista.length - MAX_ALERTAS;
        return "<ul class=\"alertas\">" + lista.slice(0, MAX_ALERTAS).map(function (a) {
            var desde = Date.parse(a.desde);
            var t = isNaN(desde) ? "" : duracion(ahora - desde / 1000);
            return "<li class=\"" + nivelAlerta(a) + (compactas ? " compacta" : "") + "\"><span class=\"punto\"></span><div><b>" + esc(a.nombre) +
                (a.wan ? " <small>" + esc(a.wan) + "</small>" : "") + "</b>" + (compactas ? "" : "<span>" + esc(a.resumen) + "</span>") + "</div>" +
                "<time>" + esc(t) + "</time></li>";
        }).join("") + (resto > 0 ? "<li class=\"mas\">y " + resto + (resto === 1 ? " alerta más: " : " alertas más: ") +
            lista.slice(MAX_ALERTAS).map(function (a) {
                return "<span class=\"" + nivelAlerta(a) + "\">" + esc(a.nombre) + (a.wan ? " " + esc(a.wan) : "") + "</span>";
            }).join(" · ") + "</li>" : "") + "</ul>";
    }
    function fila(nivel, nombre, valor) {
        return "<div class=\"fila " + nivel + "\"><span>" + nombre + "</span><b>" + valor + "</b></div>";
    }
    // Solo los contadores SMART que no están a cero: «— pendientes · 0 incorregibles · 0 reasignados»
    // de un disco sano ocupaba una línea entera para no decir nada, y con errores pasaba a dos.
    function detalleDisco(d) {
        if (d.lectura_ok === 0) return "sin lectura SMART";
        var partes = [];
        if ((d.errores_kernel || 0) > 0) partes.push(numero(d.errores_kernel) + " errores del enlace en 15 min");
        if (d.salud === 0) partes.push("SMART FALLA");
        ["pendientes", "incorregibles", "reasignados"].forEach(function (k) {
            if ((d[k] || 0) > 0) partes.push(numero(d[k]) + " " + k);
        });
        if (!partes.length) partes.push("SMART sano");
        if (hay(d.temperatura_c)) partes.push(numero(d.temperatura_c) + " °C");
        return partes.join(" · ");
    }
    // Filas del panel Host como datos: nivel, nombre, valor completo y valor corto (el que lleva en
    // la fila «En orden» cuando no cabe todo).
    function filasHost(h) {
        var filas = [];
        (h.discos || []).forEach(function (d) {
            // «HDD sda» y no «Disco sda · HDD»: en la columna de 92 px ocupaba dos líneas
            var tipo = d.rotacional === 1 ? "HDD " : d.rotacional === 0 ? "SSD " : "Disco ";
            filas.push({ nivel: nivelDisco(d), nombre: tipo + esc(d.disco), valor: detalleDisco(d),
                corto: hay(d.temperatura_c) ? numero(d.temperatura_c) + " °C" : "sano" });
        });
        (h.fs || []).forEach(function (f) {
            var nombre = PUNTOS[f.punto] || (/nas/.test(f.punto) ? "NAS" : esc(f.punto));
            var r = libreRatio(f);
            var valor = f.montado === 0 ? "NO MONTADO"
                : porcentaje(r, 1) + " libre <small>(" + bytes(f.libre_bytes) + " de " + bytes(f.tamano_bytes) + ")</small>";
            // <progress> y no un atributo de estilo: la CSP no admite estilos en línea
            var barra = hay(r) ? "<progress class=\"barra\" max=\"100\" value=\"" + Math.max(0, Math.min(100, (1 - r) * 100)).toFixed(1) + "\"></progress>" : "";
            filas.push({ nivel: nivelFs(f), nombre: nombre, valor: valor + barra, corto: porcentaje(r, 0) + " libre" });
        });
        return filas;
    }
    // La frescura de Thor va en el título de Host y no en una fila: afecta a todo el panel, y
    // como fila era la primera en quedarse sin sitio.
    function frescuraHost(h) {
        if (!hay(h.thor_hace_s)) return { nivel: "nodato", texto: "sin datos de Thor" };
        if (h.thor_hace_s > 300) return { nivel: "aviso", texto: "datos de hace " + duracion(h.thor_hace_s) };
        return null;
    }
    // Densidad del panel Host. El navegador empieza en 0 y sube mientras el panel desborde:
    //   0  todas las filas completas, en su orden de siempre
    //   1  primero lo que no está en orden; discos y volúmenes sanos, juntos en «En orden» con su cifra
    //   2  como 1, pero «En orden» solo los nombra
    // Así lo que se queda sin sitio es siempre lo que está bien, nunca un aviso.
    var DENSIDADES = 3;
    function vistaHost(h, densidad) {
        var filas = filasHost(h);
        var d = densidad || 0;
        if (d === 0) return filas.map(function (f) { return fila(f.nivel, f.nombre, f.valor); }).join("");
        var sanas = filas.filter(function (f) { return f.nivel === "ok"; });
        var html = filas.filter(function (f) { return f.nivel !== "ok"; }).map(function (f) { return fila(f.nivel, f.nombre, f.valor); }).join("");
        if (sanas.length) {
            html += fila("ok", "En orden", "<span class=\"lista\">" + sanas.map(function (f) {
                return d === 2 ? "<span class=\"ok\">" + f.nombre + "</span>"
                    : "<span class=\"ok\"><small>" + f.nombre + "</small>" + f.corto + "</span>";
            }).join("") + "</span>");
        }
        return html;
    }
    // Respaldos: panel propio en la columna de las WAN, que tenía alto de sobra; en Host eran la
    // fila que primero se quedaba sin sitio. Una línea, cada uno con su color.
    function vistaRespaldos(h) {
        // Un resumen anterior a los respaldos por nombre solo trae el de Yggdrasil
        var lista = h.respaldos && h.respaldos.length ? h.respaldos : [{ nombre: "yggdrasil", hace_h: (h.respaldo || {}).hace_h }];
        return "<span class=\"lista\">" + lista.map(function (rsp) {
            var propio = String(rsp.nombre || "");
            var nombre = RESPALDOS[propio] || esc(propio.charAt(0).toUpperCase() + propio.slice(1));
            return "<span class=\"" + nivelRespaldo(rsp) + "\"><small>" + nombre + "</small>" +
                (hay(rsp.hace_h) ? duracion(rsp.hace_h * 3600) : "sin constancia") + "</span>";
        }).join("") + "</span>";
    }
    // Último recurso si ni la densidad 2 cabe: un pie que nombra lo que queda tapado, con el color
    // del peor. Recibe [{nombre, nivel}] de las filas que no se ven.
    var ORDEN_NIVEL = { critico: 0, aviso: 1, nodato: 2, ok: 3 };
    function vistaOcultas(filas) {
        if (!filas.length) return null;
        var peor = filas.map(function (f) { return f.nivel; }).sort(function (a, b) { return ORDEN_NIVEL[a] - ORDEN_NIVEL[b]; })[0];
        return { nivel: peor, texto: "Sin sitio para " + filas.length + (filas.length === 1 ? " fila: " : " filas: ") +
            filas.map(function (f) { return f.nombre; }).join(" · ") };
    }
    // La propia tablet: si se queda sin batería, el tablero se apaga sin que nadie lo note. El
    // WebView da `charging` en cuanto hay algo enchufado, aunque no cargue: el 2026-10-19, con el
    // USB del PC, decía «cargando» mientras bajaba del 17 al 16 %. Por eso también avisa si la
    // carga baja con el cable puesto (bajando) o si queda poca aunque diga que carga.
    var BATERIA_BAJA = 0.2;
    function vistaBateria(nivel, cargando, bajando) {
        if (!hay(nivel)) return null;
        var pct = Math.round(nivel * 100) + " %";
        var n = nivel < 0.15 ? "critico" : "aviso";
        if (!cargando) return { nivel: n, texto: "Tablet sin cargar · " + pct };
        if (bajando) return { nivel: n, texto: "Tablet pierde carga enchufada · " + pct };
        if (nivel < BATERIA_BAJA) return { nivel: n, texto: "Tablet al " + pct };
        return null;
    }
    function fichaServicio(s) {
        var n = s.ok === 1 ? "ok" : "critico";
        var nombre = s.tipo === "contenedor" ? (NORDICOS[s.nombre] || sinPrefijo(s.nombre)) : sinPrefijo(s.nombre).replace(/\.(service|timer)$/, "");
        var tecnico = s.tipo === "contenedor" ? sinPrefijo(s.nombre) : (/\.timer$/.test(s.nombre) ? "temporizador" : "unidad");
        return "<span class=\"servicio " + n + "\" title=\"" + esc(s.nombre) + "\"><i></i>" + esc(nombre) +
            "<small>" + esc(tecnico) + "</small></span>";
    }
    // Los contenedores salen siempre con su nombre. Las unidades del host solo si fallan: en orden
    // se resumen en una ficha (con 18 fichas, Servicios se comía media pantalla).
    function vistaServicios(lista) {
        if (!lista.length) return "<p class=\"vacio nodato\">Sin datos de servicios</p>";
        var visibles = lista.filter(function (s) { return s.tipo === "contenedor" || s.ok !== 1; });
        var enOrden = lista.length - visibles.length;
        return visibles.map(fichaServicio).join("") + (enOrden ? "<span class=\"servicio resumen ok\"><i></i>" + enOrden +
            (enOrden === 1 ? " unidad del host en orden" : " unidades del host en orden") + "</span>" : "");
    }
    function vistaTodo(r) {
        var e = estadoGeneral(r);
        return {
            estado: e,
            wan: (r.wan || []).map(function (w) { return vistaWan(w, r.alertas, r.generado); }).join("") + vistaHogar(r.hogar),
            alertas: vistaAlertas(r.alertas || [], r.generado, r.fuentes && r.fuentes.gjallarhorn),
            nAlertas: (r.alertas || []).length,
            respaldos: vistaRespaldos(r.host || {}),
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
            $("respaldos").innerHTML = v.respaldos;
            $("servicios").innerHTML = v.servicios;
            // La columna de las WAN se aprieta (tarjetas más bajas) antes que dejar algo debajo de Servicios
            var wan = $("wan");
            wan.classList.remove("densa");
            if (wan.scrollHeight > wan.clientHeight + 1) wan.classList.add("densa");
            var frescura = frescuraHost(r.host || {}), etiqueta = $("host-frescura");
            etiqueta.hidden = !frescura;
            if (frescura) {
                etiqueta.className = frescura.nivel;
                etiqueta.textContent = "· " + frescura.texto;
            }
            ajustarDerecha(r);
        }

        // Host se queda con el alto que dejan las alertas: se pinta cada vez más denso hasta que
        // cabe; si no, las alertas pasan a una línea y se vuelve a probar; y si ni así, el pie
        // nombra las filas tapadas. Nada se pierde sin avisar.
        function ajustarDerecha(r) {
            var datos = r.host || {};
            var host = $("host"), panel = host.parentNode, pie = $("host-ocultas");
            var desborda = function () { return panel.scrollHeight > panel.clientHeight + 1; };
            pie.hidden = true;
            for (var compactas = 0; compactas < 2; compactas++) {
                if (compactas) $("alertas").innerHTML = vistaAlertas(r.alertas || [], r.generado, r.fuentes && r.fuentes.gjallarhorn, true);
                for (var d = 0; d < DENSIDADES; d++) {
                    host.innerHTML = vistaHost(datos, d);
                    if (!desborda()) return;
                }
            }
            pie.textContent = "·";
            pie.hidden = false;
            var limite = pie.getBoundingClientRect().top + 1;
            var tapadas = Array.prototype.filter.call(host.querySelectorAll(".fila"), function (f) {
                return f.getBoundingClientRect().bottom > limite;
            }).map(function (f) { return { nombre: f.firstChild.textContent, nivel: f.className.split(" ")[1] || "nodato" }; });
            var v = vistaOcultas(tapadas);
            pie.hidden = !v;
            if (v) {
                pie.className = "ocultas " + v.nivel;
                pie.textContent = v.texto;
            }
        }

        function vigilarBateria() {
            if (typeof navigator.getBattery !== "function") return;
            navigator.getBattery().then(function (b) {
                var tope = null;   // el nivel más alto visto desde que se enchufó
                var pintarBateria = function () {
                    tope = !b.charging ? null : tope === null || b.level > tope ? b.level : tope;
                    var bajando = tope !== null && tope - b.level >= 0.02;
                    var v = vistaBateria(b.level, b.charging, bajando), e = $("bateria");
                    e.hidden = !v;
                    if (v) {
                        e.className = "chip " + v.nivel;
                        e.textContent = v.texto;
                    }
                };
                pintarBateria();
                b.addEventListener("levelchange", pintarBateria);
                b.addEventListener("chargingchange", pintarBateria);
            }).catch(function () {});
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
        vigilarBateria();
        pedir();
    }

    var api = {
        esc: esc, numero: numero, porcentaje: porcentaje, bytes: bytes, duracion: duracion,
        enMedicion: enMedicion, nivelWan: nivelWan, nivelDisco: nivelDisco, nivelFs: nivelFs, nivelRespaldo: nivelRespaldo,
        estadoGeneral: estadoGeneral, vistaWan: vistaWan, vistaAlertas: vistaAlertas, vistaHost: vistaHost, vistaRespaldos: vistaRespaldos, frescuraHost: frescuraHost,
        vistaServicios: vistaServicios, vistaTodo: vistaTodo, detalleDisco: detalleDisco, vistaOcultas: vistaOcultas,
        vistaBateria: vistaBateria, DENSIDADES: DENSIDADES
    };
    if (typeof module === "object" && module.exports) {
        module.exports = api;
    } else {
        iniciar();
    }
})();
