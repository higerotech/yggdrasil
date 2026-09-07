// Importa el flujo de Heimdall en Nornas la primera vez (idempotente) e inyecta las credenciales
// MQTT del usuario "nornas" desde el entorno, usando la Admin API de Node-RED. Así las
// credenciales nunca viajan en flows.json y el despliegue no necesita pasos manuales.
import { readFileSync } from "node:fs";

const base = process.env.NORNAS_ADMIN_URL || "http://nornas:1880";
const admin = process.env.NORNAS_ADMIN_USER || "admin";
const clave = process.env.NORNAS_ADMIN_PASSWORD;
const mqttUser = process.env.MQTT_NORNAS_USER || "nornas";
const mqttPass = process.env.MQTT_NORNAS_PASSWORD;
const ruta = process.env.FLUJO || "/flujos/heimdall-alertas.json";
const TAB = "heimdall.tab";

if (!clave || !mqttPass) {
  console.error("importar-flujo: faltan NORNAS_ADMIN_PASSWORD o MQTT_NORNAS_PASSWORD");
  process.exit(1);
}

async function esperarNornas() {
  for (let i = 0; i < 60; i++) {
    try { const r = await fetch(base + "/"); if (r.status < 500) return; } catch {}
    await new Promise((res) => setTimeout(res, 2000));
  }
  throw new Error("Nornas no responde en " + base);
}

await esperarNornas();
const tok = await fetch(base + "/auth/token", {
  method: "POST",
  headers: { "Content-Type": "application/x-www-form-urlencoded" },
  body: new URLSearchParams({ client_id: "node-red-admin", grant_type: "password", scope: "*", username: admin, password: clave }),
});
if (!tok.ok) throw new Error(`autenticación en Nornas: HTTP ${tok.status}`);
const { access_token } = await tok.json();
const auth = { Authorization: `Bearer ${access_token}`, "Node-RED-API-Version": "v2" };

const actual = await (await fetch(base + "/flows", { headers: auth })).json();
const existentes = actual.flows || [];
const flujo = JSON.parse(readFileSync(ruta, "utf8"));
const revDe = (nodos) => { const t = nodos.find((n) => n.id === TAB); const e = (t && t.env || []).find((x) => x.name === "HEIMDALL_FLOW_REV"); return e ? e.value : null; };
const revNueva = revDe(flujo), revActual = revDe(existentes);
if (existentes.some((n) => n.id === TAB) && revActual === revNueva) {
  console.log(`importar-flujo: el flujo Heimdall ya está desplegado en la revisión ${revActual}; sin cambios`);
  process.exit(0);
}
// Sustituye solo los nodos de Heimdall (pestaña, sus nodos y el broker Ratatosk); conserva el resto.
const propios = new Set(flujo.map((n) => n.id));
const conservados = existentes.filter((n) => n.id !== TAB && n.z !== TAB && !propios.has(n.id));
for (const n of flujo) {
  if (n.type === "mqtt-broker") n.credentials = { user: mqttUser, password: mqttPass };
}
const r = await fetch(base + "/flows", {
  method: "POST",
  headers: { ...auth, "Content-Type": "application/json", "Node-RED-Deployment-Type": "full" },
  body: JSON.stringify({ flows: [...conservados, ...flujo] }),
});
if (!r.ok) throw new Error(`despliegue del flujo: HTTP ${r.status} ${await r.text()}`);
console.log(`importar-flujo: flujo Heimdall ${revActual ? "actualizado de " + revActual + " a " : "importado en la revisión "}${revNueva} (${flujo.length} nodos) con credenciales MQTT de ${mqttUser}`);
