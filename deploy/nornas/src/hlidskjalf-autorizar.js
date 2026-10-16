// Nodo function "Autorizar tablero": token de solo lectura de Hlidskjalf (HLIDSKJALF_TOKEN), que
// la página manda como Bearer. Es otro token que el del webhook: quien lo tenga ve el estado de
// midgard, pero no puede inyectar alertas. Sin token configurado, o con uno corto, el tablero
// queda cerrado (503) en vez de abierto. Salida 1 = autorizado, salida 2 = respuesta de error.
const esperado = env.get("HLIDSKJALF_TOKEN") || "";
const igual = global.get("secretoIgual");
const cabecera = (msg.req && msg.req.headers && msg.req.headers.authorization) || "";
const recibido = cabecera.startsWith("Bearer ") ? cabecera.slice(7) : "";
msg.headers = { "Cache-Control": "no-store" };
if (esperado.length < 32 || typeof igual !== "function") {
    msg.statusCode = 503;
    msg.payload = { error: "tablero sin configurar: falta HLIDSKJALF_TOKEN (32 caracteres o más) en Nornas" };
    return [null, msg];
}
if (!recibido || !igual(recibido, esperado)) {
    msg.statusCode = 401;
    msg.payload = { error: "no autorizado" };
    return [null, msg];
}
return [msg, null];
