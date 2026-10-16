#!/usr/bin/env python3
"""Comprueba que ningun grupo de reglas se evalua con un intervalo que deje sus series vacias.

Prometheus guarda la muestra de cada evaluacion con la hora del hueco alineado del grupo, y si la
evaluacion arranca un instante antes de ese hueco usa el ANTERIOR: la muestra mas nueva puede tener
hasta DOS intervalos de antiguedad. Si eso supera el lookback-delta (5m por defecto), las consultas
instantaneas no la encuentran. El 2026-10-16 los grupos de 5m dejaban vacias wan:disponibilidad:30d
(paneles de Odin sin datos) y wan:slo_throughput_mbps (WanThroughputBajo ciega).

Regla: 2 * intervalo < lookback-delta. Sin dependencias externas: lee el YAML con expresiones
regulares porque solo necesita `- name:` e `interval:` de cada grupo.
Uso:  python3 deploy/prometheus/tests/intervalos.py
"""
import pathlib
import re
import sys

AQUI = pathlib.Path(__file__).resolve().parent
LOOKBACK_S = 300  # --query.lookback-delta por defecto; Mimir no lo cambia
UNIDADES = {"ms": 0.001, "s": 1, "m": 60, "h": 3600}


def segundos(valor):
    total = 0.0
    for numero, unidad in re.findall(r"(\d+)(ms|s|m|h)", valor):
        total += int(numero) * UNIDADES[unidad]
    if total == 0:
        raise ValueError(f"intervalo no reconocido: {valor!r}")
    return total


config = (AQUI.parent / "prometheus.yml").read_text(encoding="utf-8")
global_m = re.search(r"^\s+evaluation_interval:\s*(\S+)", config, re.M)
por_defecto = segundos(global_m.group(1)) if global_m else 60

fallos = 0
for fichero in sorted((AQUI.parent / "rules").glob("*.yml")):
    grupo = None
    for linea in fichero.read_text(encoding="utf-8").splitlines() + ["  - name: __fin__"]:
        nombre = re.match(r"^  - name:\s*(\S+)", linea)
        if nombre:
            if grupo is not None:
                intervalo = grupo[1] if grupo[1] is not None else por_defecto
                ok = 2 * intervalo < LOOKBACK_S
                print(f"{'ok  ' if ok else 'FALLO'} {fichero.name}:{grupo[0]} interval={intervalo:g}s"
                      f" (peor antiguedad {2 * intervalo:g}s, lookback {LOOKBACK_S}s)")
                fallos += not ok
            grupo = [nombre.group(1), None]
            continue
        iv = re.match(r"^    interval:\s*(\S+)", linea)
        if iv and grupo is not None:
            grupo[1] = segundos(iv.group(1))

print("todos los grupos dejan sus series consultables" if not fallos else f"{fallos} grupo(s) con intervalo demasiado largo")
sys.exit(1 if fallos else 0)
