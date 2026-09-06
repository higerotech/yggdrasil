# Imágenes pineadas (cadena de suministro, A03)

Digests tomados de Docker Hub el 2026-09-05. El Compose pinea por tag inmutable de versión; la base
de Sleipnir se pinea además por digest en su `Dockerfile` porque `alpine:3.22` es un tag móvil.
Para actualizar: cambiar el tag, anotar el digest nuevo aquí, dejar que Trivy lo escanee en el PR
(`validar-configs.yml`) y registrar el cambio en el CHANGELOG. El triaje de vulnerabilidades y la
política de aceptación están en `docs/03-implementation/cadena-suministro.md`.

| Imagen | Tag | Digest del índice (multi-arch) | Digest linux/amd64 | Publicada | Uso |
|---|---|---|---|---|---|
| `prom/prometheus` | `v3.14.0` | `sha256:5ce7540c3c00ef4ab0c9d2c995c6a5b9c421f44b4a115d97a2c7af3b1c21cbb0` | `sha256:e906cef998316bbe319f98711e1b4d8613ad37e14b08ff831d7036e77b7464f9` | 2026-08-18 | Mimir |
| `prom/blackbox-exporter` | `v0.28.0` | `sha256:e753ff9f3fc458d02cca5eddab5a77e1c175eee484a8925ac7d524f04366c2fc` | `sha256:43027b43fb785b7c5adc53bd3b5dbc1a258270a2e8aff24f477b45c4e38dac68` | 2025-12-06 | Huginn y Muninn (última release publicada) |
| `prom/alertmanager` | `v0.34.0` | `sha256:690c7b525f4367aa91f73e2f91c632206d32e97c6384bdbf2fb7a861b420340d` | `sha256:268d4bf0e4bc0fe6dbdef6a59ce81a2918c88458bf8edf7dd0572ad372a093e6` | 2026-08-16 | Gjallarhorn |
| `grafana/grafana` | `12.4.10` | `sha256:c132a683b2430fff9115a29b2a79c8ab97540cdcc90846e3c81878c778ca3596` | `sha256:27e80e0f4fa3d423bcbbbb3418f2a6475833f94a2a88b6f2547c74830ce4286e` | 2026-09-01 | Odín (línea 12.x, mantenida) |
| `alpine` | `3.22` | `sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce` | `sha256:7c8cb692ae09657cbc4a3f3cbd0e8d5a2690ba38386aaaf252dbb060bf5eb2e6` | 2026-06-22 | Base de Sleipnir `0.1.1` (pineada por digest; `apk upgrade` en el build) |

Dependencia Python de Sleipnir: `speedtest-cli==2.1.3` (PyPI), instalada en la imagen.

Imágenes propias publicadas por `build-and-push.yml` en cada push a `main` (ADR-0005): `ghcr.io/higerotech/yggdrasil-sleipnir` y `ghcr.io/higerotech/yggdrasil-sync`, tag `sha-<7>` del commit (más `latest`, que el receptor nunca usa). Ambas sobre la misma base alpine pineada por digest; Trivy las escanea en CI al construirse en el PR.

## Historial de pines
| Fecha | Cambio | Motivo |
|---|---|---|
| 2026-09-05 | Pines iniciales: prometheus `v3.5.0`, blackbox `v0.27.0`, alertmanager `v0.28.1`, grafana `12.1.1` | Gate 2, PR #7 |
| 2026-09-05 | prometheus → `v3.14.0`, alertmanager → `v0.34.0`, blackbox → `v0.28.0`, grafana → `12.4.10`; Sleipnir `0.1.1` con `apk upgrade` | Triaje de Trivy: los pines de 2025 arrastraban CVEs de Go y `x/*` ya corregidos río arriba (de 41 a 123 hallazgos por imagen a entre 2 y 6, salvo blackbox) |

## Escaneo de vulnerabilidades
Trivy 0.66.0, CRITICAL/HIGH, `--ignore-unfixed`, en cada PR que toque `deploy/` y cada lunes
(disparo programado). Resumen tras el re-pineo del 2026-09-05:

| Imagen | Hallazgos | CRITICAL | Nota |
|---|---|---|---|
| `prom/prometheus:v3.14.0` | 2 por binario | 1 | `x/crypto` 0.55.0 y `grpc` 1.83.1 sin release upstream aún |
| `prom/alertmanager:v0.34.0` | 2 (`alertmanager`), 4 (`amtool`) | 1 | Ídem; `x/mod` solo en la CLI |
| `prom/blackbox-exporter:v0.28.0` | 40 | 3 | Última release (2025-12); Go `stdlib`, `x/crypto`, `grpc`, `x/net`; mitigado por red |
| `grafana/grafana:12.4.10` | 6 | 0 | OpenSSL pendiente de paquete Alpine; tempo/thrift no usados |
| `yggdrasil/sleipnir:0.1.1` | 2 | 0 | OpenSSL pendiente de paquete Alpine |

El residual, su exposición real y la política de aceptación están en `docs/03-implementation/cadena-suministro.md`.
