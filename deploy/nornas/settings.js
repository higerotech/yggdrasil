// Nornas — settings de Node-RED (montado de solo lectura en /data/settings.js).
// Los secretos vienen del entorno (.env): editor con autenticación obligatoria (RS01) y secreto
// estable para cifrar las credenciales de los flujos (flows_cred.json).
let bcrypt;
try { bcrypt = require("bcryptjs"); } catch (e) { bcrypt = require("/usr/src/node-red/node_modules/bcryptjs"); }

function exigir(nombre) {
  const v = process.env[nombre];
  if (!v) throw new Error(`Nornas: falta la variable de entorno ${nombre} (ver deploy/.env.example)`);
  return v;
}

const crypto = require("node:crypto");

// Herramientas para los nodos function del tablero Hlidskjalf: el sandbox de las functions no
// trae fetch ni crypto, y functionExternalModules sigue desactivado. Se exponen dos funciones
// concretas, no los módulos enteros.
const herramientas = {
  // GET a la red interna con tiempo máximo: una consulta colgada no debe dejar colgado el tablero.
  consultarJson: async (url, ms = 5000) => {
    const r = await fetch(url, { signal: AbortSignal.timeout(ms), headers: { Accept: "application/json" } });
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    return r.json();
  },
  // Comparación de secretos en tiempo constante.
  secretoIgual: (a, b) => {
    const x = Buffer.from(String(a)), y = Buffer.from(String(b));
    return x.length === y.length && crypto.timingSafeEqual(x, y);
  },
};

module.exports = {
  flowFile: "flows.json",
  flowFilePretty: true,
  credentialSecret: exigir("NORNAS_CREDENTIAL_SECRET"),
  uiPort: 1880,
  httpAdminRoot: "/",
  httpNodeRoot: "/",

  adminAuth: {
    type: "credentials",
    users: [{
      username: process.env.NORNAS_ADMIN_USER || "admin",
      password: bcrypt.hashSync(exigir("NORNAS_ADMIN_PASSWORD"), 8),
      permissions: "*",
    }],
  },

  logging: { console: { level: "info", metrics: false, audit: true } },
  diagnostics: { enabled: true, ui: false },
  runtimeState: { enabled: false, ui: false },
  exportGlobalContextKeys: false,
  externalModules: {
    autoInstall: false,
    palette: { allowInstall: true, allowUpload: false },   // instalar nodos exige login de admin
    modules: { allowInstall: false },                      // sin require() dinámico en functions
  },
  functionExternalModules: false,
  functionTimeout: 0,
  functionGlobalContext: herramientas,
  debugMaxLength: 1000,
  mqttReconnectTime: 15000,
  editorTheme: {
    projects: { enabled: false },
    tours: false,
    header: { title: "Nornas · Yggdrasil" },
  },
};
