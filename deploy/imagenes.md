# Imágenes pineadas (cadena de suministro, A03)

Digests tomados de Docker Hub el 2026-09-05. El Compose pinea por tag inmutable de versión; la
base de Sleipnir se pinea además por digest en su `Dockerfile` porque `alpine:3.22` es un tag
móvil. Para actualizar: cambiar el tag, anotar el digest nuevo aquí, escanear con Trivy
(`validar-configs.yml` lo hace en cada PR) y registrar el cambio en el CHANGELOG.

| Imagen | Tag | Digest del índice (multi-arch) | Digest linux/amd64 | Publicada | Uso |
|---|---|---|---|---|---|
| `prom/prometheus` | `v3.5.0` | `sha256:63805ebb8d2b3920190daf1cb14a60871b16fd38bed42b857a3182bc621f4996` | `sha256:8672a850efe2f9874702406c8318704edb363587f8c2ca88586b4c8fdb5cea24` | 2025-07-14 | Mimir (LTS 3.5) |
| `prom/blackbox-exporter` | `v0.27.0` | `sha256:a50c4c0eda297baa1678cd4dc4712a67fdea713b832d43ce7fcc5f9bea05094d` | `sha256:63ec596b02095ac6b09eb990d390a7a2eb21cc505f5a8f11dfc1eb796bb0aa23` | 2025-06-30 | Huginn y Muninn |
| `prom/alertmanager` | `v0.28.1` | `sha256:27c475db5fb156cab31d5c18a4251ac7ed567746a2483ff264516437a39b15ba` | `sha256:220da6995a919b9ee6e0d3da7ca5f09802f3088007af56be22160314d2485b54` | 2025-03-07 | Gjallarhorn |
| `grafana/grafana` | `12.1.1` | `sha256:a1701c2180249361737a99a01bc770db39381640e4d631825d38ff4535efa47d` | `sha256:5749a0e982878aedaa2d320ed14d3bdce7a040a938f482258670009d419a597f` | 2025-08-13 | Odín |
| `alpine` | `3.22` | `sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce` | `sha256:7c8cb692ae09657cbc4a3f3cbd0e8d5a2690ba38386aaaf252dbb060bf5eb2e6` | 2026-06-22 | Base de Sleipnir (pineada por digest) |

Dependencia Python de Sleipnir: `speedtest-cli==2.1.3` (PyPI), instalada en la imagen.

## Escaneo de vulnerabilidades (Trivy 0.66.0, CRITICAL/HIGH, `--ignore-unfixed`)

Primer informe en CI el 2026-09-05 (run `validar-configs`, PR #7); pendiente de triaje humano (Gate 2).
La mayoría son CVEs de la biblioteca estándar de Go y de paquetes del SO base que el upstream
aún no ha reempaquetado; el criterio de aceptación se decide en el HITL de Gate 2.

| Imagen | Hallazgos | CRITICAL |
|---|---|---|
| `prom/prometheus:v3.5.0` | 45 | 3 |
| `prom/alertmanager:v0.28.1` | 41 a 43 según objetivo | 2 |
| `prom/blackbox-exporter:v0.27.0` | 42 | 3 |
| `grafana/grafana:12.1.1` | 23 (SO alpine 3.22.1), 70 (binario Go), 30 (dependencias) | 2 / 8 / 3 |

Trivy no bloquea el PR (`--exit-code 0`) hasta que exista una política de triaje aceptada.
