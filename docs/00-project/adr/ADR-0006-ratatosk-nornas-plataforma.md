# ADR-0006: Ratatosk y Nornas como servicios de plataforma en el Compose de Yggdrasil

* **Estado:** accepted
* **Fecha:** 2026-09-05
* **Decisores:** Jeremi
* **Fase AI-DLC:** 02-design
* **Versión:** 1.0.0
* **ID:** ADR-0006
* **Supersede / Superseded-by:** sustituye la premisa "reutiliza el broker existente" del charter y "Node-RED y Mosquitto existentes" del PRD y de `architecture.md`
* **Controles OWASP afectados:** A01 (editor de Node-RED autenticado), A05 (ACL por usuario en el bus, límites del broker), A07 (una credencial por cliente MQTT)

## Contexto
El diseño de Gate 1 asumía un broker MQTT y un Node-RED ya existentes en el appliance. Al revisar
midgard para el despliegue continuo no existe ninguno de los dos. `nvr-frigate` diseña su propio
Mosquitto (sin ACL) y trata a Node-RED como sistema externo "planificado en el appliance", y su
ADR-0005 lo convierte además en evaluador y notificador de Frigate. Es decir, los dos proyectos
dependen de piezas que nadie posee. `naming.md` y el C4 Container ya colocan a Ratatosk y Nornas
dentro del boundary de Yggdrasil y fuera de Heimdall: son de la plataforma.

## Decisión
Yggdrasil despliega y posee **Ratatosk** (Mosquitto 2.0.22) y **Nornas** (Node-RED 4.1.14) como
servicios de plataforma en su propio Compose, en midgard:
- **Ratatosk**: un listener 1883 publicado solo en la IP LAN, `allow_anonymous false`, una
  credencial por cliente (`nornas`, `frigate`, `iot`) y ACL por usuario: solo `nornas` escribe en
  `midgard/#`, `frigate` en `frigate/#`, `iot` solo lee. Límites de conexiones, cola y tamaño de
  mensaje. El archivo de contraseñas se genera al arrancar a partir de `.env`, en el volumen de datos.
- **Nornas**: editor con autenticación obligatoria (settings.js con bcrypt desde `.env`), publicado
  solo en la IP LAN; secreto estable para cifrar credenciales de flujos; sin `require` dinámico en
  functions. Alertmanager le entrega el webhook por la red interna de Compose (`nornas:1880`), ya no
  por `host.docker.internal`.
- **Provisión sin pasos manuales**: `nornas-init` importa el flujo de Heimdall por la Admin API en
  el primer arranque e inyecta las credenciales MQTT de `nornas`; es idempotente y no toca flujos
  que el usuario haya añadido después.
- Se descartó un listener interno anónimo para Nornas: la regla `forward` del router deja pasar
  tráfico de la LAN a cualquier IP de contenedor, así que un listener sin credenciales sería
  alcanzable desde la LAN aunque no esté publicado.
- **Fenrir** (`nvr-frigate`) pasa a ser cliente de Ratatosk con el usuario `frigate` a través de la IP
  LAN y puede retirar su Mosquitto; esa decisión se toma en su repo.

## Alternativas consideradas
| Opción | Pros | Contras | Riesgo de seguridad |
|---|---|---|---|
| Servicios de plataforma en el Compose de Yggdrasil (elegida) | Coherente con `naming.md` y el C4; Node-RED lo usan ambos proyectos; un solo despliegue continuo | Cambia una premisa de Gate 1; coordinación con `nvr-frigate` | Auth y ACL bajo control propio; dos superficies nuevas en la LAN (1883, 1880), ambas autenticadas |
| Usar el Mosquitto de `nvr-frigate` | Ya diseñado allí | El bus de la plataforma dependería del NVR (RF05 caería con Fenrir); Node-RED seguiría sin dueño | Sin ACL en ese diseño |
| Stack aparte para el bus | Ciclo de vida aislado | Un tercer despliegue; Compose no recrea servicios sin cambios, la ganancia es pequeña | Igual |
| Listener anónimo interno para Nornas | Sin credenciales que provisionar | Alcanzable desde la LAN por la regla forward del router | Publicación anónima de estados falsos (T3) |

## Consecuencias
- Positivas: RF05 y las notificaciones dejan de depender de un servicio inexistente; T3 pasa de
  "control heredado" a control propio con ACL; una credencial por cliente; provisión automática.
- Negativas / deuda asumida: RNF01 sube de 1088 a 1408 MB (dentro de 1.5 GB); dos imágenes más en el
  informe de Trivy; el editor de Node-RED es una superficie nueva en la LAN (autenticada); instalar
  nodos desde la paleta queda permitido a administradores (riesgo aceptado, revisable); las versiones
  nuevas del flujo de Heimdall requieren borrar la pestaña y relanzar `nornas-init`.
- Impacto en threat model: filas nuevas para Node-RED (editor) y actualización de la fila MQTT y de
  T3; el webhook T4 deja de cruzar el host.
- Impacto en `nvr-frigate`: puede consumir Ratatosk (`frigate/#`) y retirar su broker; hasta entonces
  ambos pueden convivir en puertos distintos.
- Condiciones de revisión: si aparece un tercer proyecto que necesite el bus con ciclo de vida
  distinto, evaluar el stack aparte; si la superficie del editor preocupa, restringir 1880 a WireGuard.
