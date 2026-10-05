// Nodo function "Respuesta de ntfy": deja constancia de si ntfy aceptó el aviso. Un fallo va a
// node.warn, que llega al log del contenedor (docker logs yggdrasil-node-red). Solo se registra el
// código y el título, nunca la URL: lleva el tema, que es la credencial.
// Con un error de red, http request pone en statusCode el código del error (p. ej. "ENOTFOUND").
const codigo = msg.statusCode;
if (typeof codigo === "number" && codigo >= 200 && codigo < 300) {
    node.status({ fill: "green", shape: "dot", text: `ntfy ${codigo}: ${msg.topic || ""}` });
} else {
    node.status({ fill: "red", shape: "dot", text: `ntfy ${codigo || "sin respuesta"}` });
    node.warn(`ntfy rechazó el aviso "${msg.topic || ""}": ${codigo || "sin respuesta"}`);
}
return null;
