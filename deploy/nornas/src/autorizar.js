// Nodo function "Autorizar": verifica el token Bearer que envía Gjallarhorn (Alertmanager).
// El valor esperado se lee del entorno del proceso de Node-RED (NORNAS_WEBHOOK_TOKEN) o, si no
// existe, del contexto global. Salida 1 = autorizado, salida 2 = respuesta 401.
const esperado = env.get("NORNAS_WEBHOOK_TOKEN") || global.get("NORNAS_WEBHOOK_TOKEN");
const recibido = (msg.req && msg.req.headers && msg.req.headers.authorization) || "";
if (!esperado || recibido !== "Bearer " + esperado) {
    msg.statusCode = 401;
    msg.payload = { error: "no autorizado" };
    return [null, msg];
}
return [msg, null];
