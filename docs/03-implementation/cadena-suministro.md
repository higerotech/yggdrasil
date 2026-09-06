# Cadena de suministro — triaje de vulnerabilidades (Gate 2)

* **Estado:** approved
* **Fecha:** 2026-09-05
* **Decisores:** Jeremi
* **Fase AI-DLC:** 03-implementation
* **Versión:** 0.3.0
* **Gate:** 2
* **Herramienta:** Trivy 0.66.0, severidades HIGH y CRITICAL, `--ignore-unfixed` en CI
* **Control OWASP:** A03 (Software Supply Chain Failures)

## Qué se hizo
El primer escaneo en CI (PR #7) devolvió entre 41 y 123 hallazgos por imagen. La causa no era el
stack sino la antigüedad de los pines: las versiones elegidas eran de mediados de 2025 y el grueso de
los CVEs vive en la biblioteca estándar de Go y en `golang.org/x/*`, corregidos río arriba en
releases posteriores. La acción de triaje fue **actualizar los pines a las releases parcheadas más
recientes de cada proyecto**, re-escanear y documentar el residual.

| Imagen | Pin anterior | Pin nuevo | Hallazgos antes → después |
|---|---|---|---|
| Prometheus (Mimir) | `v3.5.0` (2025-07) | `v3.14.0` (2026-08-18) | 47 → 2 por binario |
| Alertmanager (Gjallarhorn) | `v0.28.1` (2025-03) | `v0.34.0` (2026-08-16) | 41 → 2 (`alertmanager`), 43 → 4 (`amtool`) |
| blackbox_exporter (Huginn y Muninn) | `v0.27.0` (2025-06) | `v0.28.0` (2025-12-06, última publicada) | 42 → 40 |
| Grafana (Odín) | `12.1.1` (2025-08) | `12.4.10` (2026-09-01) | 123 → 6 |
| Sleipnir (propia) | alpine 3.22 | alpine 3.22 + `apk upgrade` en el build | 2 → 2 |

## Residual por imagen

| Imagen | CVE | Paquete | Instalado → corregido en | Sev. | Situación |
|---|---|---|---|---|---|
| Prometheus, Alertmanager | CVE-2026-56854 | `golang.org/x/crypto` | 0.54.0 → 0.55.0 | CRITICAL | Sin release upstream que lo incluya todavía (ambas releases son de agosto de 2026) |
| Prometheus, Alertmanager, Grafana | CVE-2026-84304 | `google.golang.org/grpc` | 1.82.1 → 1.83.1 | HIGH | Ídem |
| Alertmanager (`amtool`) | CVE-2026-56864, CVE-2026-56865 | `golang.org/x/mod` | 0.38.0 → 0.40.0 | HIGH | Solo afecta a la CLI `amtool`, que no corre como servicio |
| blackbox_exporter | CVE-2025-68121 + 20 HIGH | Go `stdlib` 1.25.5 | → 1.25.7 | CRITICAL | `v0.28.0` es la última release; no hay binario reconstruido con Go parcheado |
| blackbox_exporter | CVE-2026-56854 + 9 HIGH | `golang.org/x/crypto` 0.45.0 | → 0.55.0 | CRITICAL | Ídem |
| blackbox_exporter | CVE-2026-33186 + 2 HIGH | `google.golang.org/grpc` 1.77.0 | → 1.83.1 | CRITICAL | Ídem; blackbox no expone gRPC en nuestra configuración |
| blackbox_exporter | 5 HIGH | `golang.org/x/net` 0.47.0 | → 0.56.0 | HIGH | Ídem |
| Grafana, Sleipnir | CVE-2026-14456 | `libcrypto3`, `libssl3` (OpenSSL 3.5.7-r0) | → 3.5.8-r0 | HIGH | El paquete corregido no está aún en ningún repositorio estable de Alpine (3.22 ni 3.24) |
| Grafana | CVE-2026-21728, CVE-2026-28377, CVE-2026-43871 | `grafana/tempo`, `apache/thrift` | dependencias internas | HIGH | Vías de tracing/ingesta que Odín no usa en este despliegue |

## Exposición real y mitigaciones de diseño
- **Mimir y Gjallarhorn** no publican puertos: solo son alcanzables desde la red interna de Compose
  (ADR-0003). Un CVE en su servidor HTTP o en TLS exige ya estar dentro de esa red.
- **Huginn y Muninn** (el residual más alto) corre en host-mode pero escucha solo en la IP de docker0;
  la LAN y las WAN no llegan a 9115. Actúa como *cliente* ICMP/TLS hacia objetivos que controlamos
  (1.1.1.1, 8.8.8.8, gstatic); los CVEs de `x/crypto`, `grpc` y `x/net` son mayoritariamente de
  servidor o de parseo de entradas hostiles que aquí no recibe. Contenedor sin root, rootfs ro,
  `cap_drop ALL` + `NET_RAW`, `no-new-privileges`.
- **Odín** es la única superficie en la LAN (3000, ligado a la IP LAN, con autenticación y sin
  anónimo). El residual de OpenSSL depende de Alpine; el de tempo/thrift no está en uso.
- **Sleipnir** es cliente saliente; su OpenSSL afecta a la conexión hacia servidores de speedtest.

## Política de triaje propuesta (a aprobar en el HITL de Gate 2)
1. **Bloquear** en CI un CVE CRITICAL o HIGH cuya corrección **ya esté publicada en una release
   estable de la imagen** que usamos y no la hayamos adoptado. Hoy no hay ninguno en ese estado.
2. **Aceptar temporalmente**, con registro aquí, los CVEs sin release upstream que los incluya
   (`x/crypto` 0.55.0, `grpc` 1.83.1, Go 1.25.7, OpenSSL 3.5.8-r0). Revisión en cada informe.
3. **Escaneo semanal programado** (`validar-configs.yml`, lunes 06:17 UTC) además del escaneo por PR;
   cuando aparezca una release que cierre el residual, actualizar el pin y el digest en
   `deploy/imagenes.md` y anotarlo en el CHANGELOG.
4. **blackbox_exporter**: si en el siguiente informe sigue sin release, valorar construir la imagen
   desde el tag `v0.28.0` con la toolchain de Go actual (misma receta que Sleipnir) para eliminar el
   residual de `stdlib`; hasta entonces la mitigación de red es la barrera.
5. Trivy sigue en modo informe (`--exit-code 0`) hasta que la política 1 se implemente como filtro;
   la implementación del filtro (por ejemplo `.trivyignore` con fecha de caducidad por CVE aceptado)
   entra en Gate 3.

## Decisión (HITL, 2026-09-05)
El owner acepta la política de triaje, el residual documentado y mantener `blackbox_exporter v0.28.0`
con mitigación de red; la construcción desde fuente queda como opción si el próximo informe semanal
no trae release nueva. Gate 2 cerrado con esta decisión.
