#!/usr/bin/env python3
"""Resolve a lens set for the benchmark runners.

    preset.py <set> <field> [N]

<set> is a preset name from ../presets/ (review, cleanup, simplify, security) or a
set from lenses.json (topic, method). lenses.json sets take the review preset's
task and report format, which is what the measured review runs used.

Fields:
  task, report_line, max_findings, scope   one value
  recon_extra                              one step per line
  lenses N                                 "<id>\\t<brief>" per lens, first N
  single                                   one brief covering every lens, for arm A
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def load(name):
    path = os.path.join(HERE, "..", "presets", f"{name}.json")
    if os.path.exists(path):
        return json.load(open(path))
    review = json.load(open(os.path.join(HERE, "..", "presets", "review.json")))
    sets = json.load(open(os.path.join(HERE, "lenses.json")))
    if name not in sets or name == "single":
        sys.exit(f"preset.py: no preset or lens set named {name}")
    return {**review, "lenses": sets[name], "single": sets["single"]["brief"]}


def single_brief(p):
    """One agent covering every lens: lenses.json has a hand-written one; presets join theirs."""
    if "single" in p:
        return p["single"]
    return "Cover every one of these, one after another:\n" + "\n".join(
        f"- {lens['id']}: {lens['brief']}" for lens in p["lenses"])


def main():
    name, field = sys.argv[1], sys.argv[2]
    p = load(name)
    if field == "lenses":
        n = int(sys.argv[3])
        if n > len(p["lenses"]):
            sys.exit(f"preset.py: {name} has {len(p['lenses'])} lenses, asked for {n}")
        for lens in p["lenses"][:n]:
            print(f"{lens['id']}\t{lens['brief']}")
    elif field == "single":
        print(single_brief(p))
    else:
        value = p[field]
        print("\n".join(value) if isinstance(value, list) else value)


if __name__ == "__main__":
    main()
