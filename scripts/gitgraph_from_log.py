#!/usr/bin/env python3
"""Genera documentación viva del historial de un repo: un gitGraph Mermaid + una bitácora
fiel de commits y merges, derivados de `git log` (no escritos a mano).

Uso:
    python scripts/gitgraph_from_log.py <ruta-repo> [--branch main] [--out archivo.md]

Sin --out imprime a stdout un fragmento Markdown listo para pegar en
docs/03-implementation/. La bitácora (tabla) es siempre fiel al repo; el gitGraph es una
reconstrucción por primer-padre (main + ramas mergeadas), válida para historias trunk-based
o GitFlow simples. Historias con merges octopus o entrelazados caen a la bitácora como fuente
de verdad y el gitGraph se marca como aproximado.
"""
import argparse
import re
import subprocess
import sys


def git(repo, *args):
    # encoding explícito: git emite UTF-8, pero sin este parámetro Python usa la
    # codificación local (cp1252 en Windows) y corrompe los acentos de autores y mensajes.
    r = subprocess.run(
        ["git", "-C", repo, *args],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if r.returncode != 0:
        raise SystemExit(f"git {' '.join(args)} falló: {r.stderr.strip()}")
    return r.stdout


def short(h):
    return h[:7]


def branch_name(subject, refs):
    m = re.search(r"Merge branch '([^']+)'", subject) or re.search(r"Merge pull request .* from [^/]+/(\S+)", subject)
    if m:
        return m.group(1)
    for r in refs.split(","):
        r = r.strip().replace("origin/", "")
        if r and r not in ("HEAD",) and not r.startswith("tag:") and r != "main" and r != "master":
            return r
    return None


def tags_of(refs):
    return [t.strip()[4:].strip() for t in refs.split(",") if t.strip().startswith("tag:")]


def build(repo, branch):
    fmt = "%H%x09%P%x09%s%x09%D"
    main = [l for l in git(repo, "log", "--first-parent", "--reverse", f"--format={fmt}", branch).splitlines() if l]
    octopus = False
    lines = ["gitGraph"]
    feat_counter = 0
    first = True
    for row in main:
        h, parents, subject, refs = (row.split("\t") + ["", "", ""])[:4]
        pl = parents.split()
        tgs = tags_of(refs)
        tag_sfx = f' tag: "{tgs[0]}"' if tgs else ""
        if len(pl) <= 1:
            lines.append(f'    commit id: "{short(h)}"{tag_sfx}')
            first = False
        else:
            if len(pl) > 2:
                octopus = True
            p1, p2 = pl[0], pl[1]
            bname = branch_name(subject, refs) or f"feature-{feat_counter}"
            feat_counter += 1
            safe = re.sub(r"[^A-Za-z0-9_/.-]", "-", bname)
            feats = [l for l in git(repo, "log", "--reverse", "--format=%H", p2, "--not", p1).splitlines() if l]
            lines.append(f"    branch {safe}")
            lines.append(f"    checkout {safe}")
            for fh in feats:
                lines.append(f'    commit id: "{short(fh)}"')
            lines.append(f"    checkout {branch if branch in ('main',) else 'main'}")
            lines.append(f"    merge {safe}{tag_sfx}")
    # Mermaid gitGraph siempre nombra la rama base 'main'; si el repo usa otra, la renombramos visualmente.
    if branch not in ("main",):
        lines = ["gitGraph"] + [re.sub(rf"\bcheckout {re.escape(branch)}\b", "checkout main", x) for x in lines[1:]]
    graph = "\n".join(lines)

    # Bitácora fiel (todos los commits, orden cronológico inverso)
    fmt2 = "%h%x09%p%x09%D%x09%an%x09%ad%x09%s"
    rows = [l for l in git(repo, "log", "--all", f"--format={fmt2}", "--date=short").splitlines() if l]
    table = ["| Commit | Tipo | Tags | Autor | Fecha | Mensaje |",
             "|---|---|---|---|---|---|"]
    for row in rows:
        h, parents, refs, an, ad, subject = (row.split("\t") + [""] * 6)[:6]
        tipo = "merge" if len(parents.split()) > 1 else "commit"
        tgs = ", ".join(tags_of(refs)) or "—"
        subject = subject.replace("|", "\\|")
        table.append(f"| `{h}` | {tipo} | {tgs} | {an} | {ad} | {subject} |")
    return graph, "\n".join(table), octopus


def render(repo, branch):
    graph, table, octopus = build(repo, branch)
    note = ("\n> Nota: historia con merge octopus/entrelazada — el gitGraph es aproximado; "
            "la bitácora es la fuente de verdad.\n") if octopus else ""
    return f"""## Historial del repositorio (documentación viva)

Derivado de `git log` con `scripts/gitgraph_from_log.py`. Regenerar tras cada merge o tag para
mantener la traza sincronizada. Los tags SemVer enlazan con las versiones del `CHANGELOG.md`.
{note}
### Grafo de commits y merges

```mermaid
{graph}
```

### Bitácora de cambios (fiel al repo)

{table}
"""


def main():
    p = argparse.ArgumentParser(description="gitGraph + bitácora desde git log")
    p.add_argument("repo")
    p.add_argument("--branch", default="main")
    p.add_argument("--out", default=None)
    a = p.parse_args()
    out = render(a.repo, a.branch)
    if a.out:
        with open(a.out, "w", encoding="utf-8") as f:
            f.write(out)
        print(f"Escrito: {a.out}")
    else:
        sys.stdout.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
