// Nodo function "Formatear ntfy": convierte un aviso de la salida push de "traducir" en una
// publicación JSON de ntfy, que el nodo http request siguiente envía.
//   entrada:  { topic: título, payload: texto, prioridad: 1..5, etiquetas: [...] }
//   NTFY_URL: URL completa del tema (https://ntfy.sh/<tema>), del entorno del contenedor.
// Se publica en JSON contra la raíz del servidor y no con cabeceras Title/Tags: las cabeceras HTTP
// no admiten bien UTF-8 y los títulos llevan tildes ("CAÍDA").
// El tema ES la credencial (quien lo conozca lee los avisos): no se registra nunca, ni en el
// estado del nodo ni en avisos.
const url = env.get("NTFY_URL") || "";
if (!url) {
    node.status({ fill: "grey", shape: "ring", text: "sin NTFY_URL: push desactivado" });
    return null;
}
const partes = url.match(/^(https?:\/\/[^/]+)\/([^/?#]+)\/?$/);
if (!partes) {
    node.status({ fill: "red", shape: "dot", text: "NTFY_URL no tiene la forma https://servidor/tema" });
    return null;
}
msg.url = partes[1] + "/";
msg.method = "POST";
msg.headers = { "Content-Type": "application/json" };
msg.payload = JSON.stringify({
    topic: partes[2],
    title: msg.topic || "Heimdall",
    message: msg.payload || msg.topic || "",
    priority: msg.prioridad || 3,
    tags: msg.etiquetas || [],
});
node.status({ fill: "blue", shape: "dot", text: "enviando: " + (msg.topic || "") });
return msg;
