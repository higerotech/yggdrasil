#!/usr/bin/env python3
"""Genera docs/03-implementation/repo-history.md (documentación viva, Gate 2) desde git log.

Envuelve a gitgraph_from_log.py (copiado del skill AI-DLC) para producir dos vistas:
  - main: releases y tags (GitFlow, primer padre)
  - develop: integración de features y back-merges
y las antepone a la cabecera de metadatos y a la tabla tag ↔ versión ↔ decisión.

Uso: python scripts/generar-historial.py   (desde la raíz del repo, tras cada merge o tag)
"""
import re
import subprocess
import sys
from datetime import date
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
SCRIPT = RAIZ / "scripts" / "gitgraph_from_log.py"
SALIDA = RAIZ / "docs" / "03-implementation" / "repo-history.md"

# Back-merges "Merge main (vX.Y.Z) en develop": el script no extrae el nombre de rama y usa
# feature-N; los renombramos por el tag que traen para que el grafo diga lo que pasó.
def renombrar_backmerges(graph: str, repo: Path) -> str:
    log = subprocess.run(["git", "-C", str(repo), "log", "--first-parent", "--format=%h%x09%s", "develop"],
                         capture_output=True, text=True, encoding="utf-8").stdout
    tags = {}
    for line in log.splitlines():
        h, _, s = line.partition("\t")
        m = re.match(r"Merge main \((v[\d.]+)\) en develop", s)
        if m:
            tags[h] = m.group(1)
    # Cada "branch feature-N" va seguido de sus commits; el merge commit del back-merge es el que
    # trae el tag en la línea "merge feature-N". Emparejamos por orden de aparición.
    # Un back-merge también puede salir nombrado "develop" o "main" cuando es la punta de la rama
    # (el script toma el nombre de las referencias); esos bloques son back-merges igualmente.
    bloques = re.findall(r"branch (feature-\d+|develop|main|master)\n", graph)
    etiquetas = [t for _, t in reversed(list(tags.items()))]   # cronológico: v0.1.0, v0.2.0, ...
    for nombre, tag in zip(bloques, etiquetas):
        nuevo = f"backmerge-{tag}"
        graph = graph.replace(f"branch {nombre}\n", f"branch {nuevo}\n", 1)
        graph = graph.replace(f"checkout {nombre}\n", f"checkout {nuevo}\n", 1)
        graph = graph.replace(f"merge {nombre}", f"merge {nuevo}", 1)
    return graph


def vista(branch: str) -> tuple[str, str]:
    # Se pasa por --out (UTF-8) y no por stdout: en Windows la consola reescribe la codificación.
    import tempfile
    with tempfile.NamedTemporaryFile("r", suffix=".md", delete=False, encoding="utf-8") as tmp:
        ruta = tmp.name
    subprocess.run([sys.executable, str(SCRIPT), str(RAIZ), "--branch", branch, "--out", ruta],
                   check=True, capture_output=True)
    out = Path(ruta).read_text(encoding="utf-8")
    Path(ruta).unlink(missing_ok=True)
    graph = re.search(r"```mermaid\n(gitGraph\n.*?)```", out, re.S).group(1)
    table = out.split("### Bitácora de cambios (fiel al repo)\n", 1)[1].strip()
    return graph, table


def main() -> int:
    g_main, tabla = vista("main")
    g_dev, _ = vista("develop")
    g_dev = renombrar_backmerges(g_dev, RAIZ)
    g_dev = g_dev.replace("checkout main\n", "checkout develop\n")
    g_dev = "%%{init: { 'gitGraph': { 'mainBranchName': 'develop' } } }%%\n" + g_dev

    tags = subprocess.run(["git", "-C", str(RAIZ), "tag", "--sort=version:refname"], capture_output=True, text=True).stdout.split()
    filas = {"v0.1.0": "0.1.0 (Gate 0) | Umbrales SLO y hosts de sondeo confirmados; licencia AGPL-3.0 | release/0.1.0 desde la punta del PR #2",
             "v0.2.0": "0.2.0 (Gate 1) | ADR-0001, ADR-0003 aceptados; ADR-0004 frontera con Fenrir | release/0.2.0 desde develop"}
    traz = "\n".join(f"| {t} | {filas.get(t, '— | — | —')} |" for t in tags)

    doc = f"""# Historial de implementación — Yggdrasil

* **Estado:** review
* **Fecha:** {date.today().isoformat()}
* **Decisores:** Jeremi
* **Fase AI-DLC:** 03-implementation
* **Versión:** 0.3.0
* **Gate:** 2
* **Rama principal:** main
* **Estrategia de branching:** GitFlow

Documento generado por `scripts/generar-historial.py` a partir de `git log`; no editar a mano.
Regenerar tras cada merge o tag. Los tags SemVer enlazan con las versiones del `CHANGELOG.md`.

## Vista de releases (`main`, primer padre)
`main` solo recibe merges de `release/*` (y `hotfix/*`) por PR con merge commit; cada merge lleva su tag.

```mermaid
{g_main}```
*Eje trazabilidad · fase 03 · evidencia Gate 2.*

## Vista de integración (`develop`)
Features por PR; los bloques `backmerge-*` son los merges de `main` a `develop` tras cada release.

```mermaid
{g_dev}```
*Eje trazabilidad · fase 03 · evidencia Gate 2.*

## Trazabilidad tag ↔ versión ↔ decisión
| Tag | Versión CHANGELOG | ADR / decisión | Nota |
|---|---|---|---|
{traz}

## Bitácora de cambios (fiel al repo)
{tabla}
"""
    SALIDA.parent.mkdir(parents=True, exist_ok=True)
    SALIDA.write_text(doc, encoding="utf-8", newline="\n")
    print(f"Escrito: {SALIDA.relative_to(RAIZ)} ({len(doc.splitlines())} líneas, {len(tags)} tags)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
