#!/usr/bin/env python3
"""Per-arm comprehensiveness and cost, from judged findings.

    analyze.py <corpus-dir> [--rates-from <corpus-dir>]

Distinct issues: findings judged real (strict pass) or matching a seeded defect are
clustered across ALL runs; two findings are one issue when they cite the same file
within 10 lines (a heuristic: it can merge two nearby bugs, or split one bug cited
at two far-apart lines). Per arm: distinct true issues, issues no other arm found,
duplicate rate inside the arm, and cost.

Cost: per-token rates are fitted by least squares on the headless runs, whose CLI
JSON reports both token usage and total_cost_usd. Fork runs are priced with the
fitted rates from their transcript usage (usage.txt). No price is typed in by hand.
"""
import glob
import hashlib
import json
import os
import re
import subprocess
import sys

import numpy as np

COLS = ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens")


def fhash(f):
    """Same rule as judge.finding_hash: review-shaped findings keep the hash their
    cached verdicts were stored under; findings with no "why" hash every field."""
    if "why" in f:
        t = f"{f.get('file')}:{f.get('line')} {f.get('title')} — {f.get('why')}"
    else:
        t = json.dumps(f, sort_keys=True)
    return hashlib.sha1(t.encode()).hexdigest()[:12]


def load(corpus):
    seeded = {d["id"] for d in json.load(open(f"{corpus}/answer-key.json"))}
    lenient = json.load(open(f"{corpus}/verdicts.json"))
    strict = json.load(open(f"{corpus}/verdicts-strict.json"))
    rpath = f"{corpus}/verdicts-rematch.json"
    rematched = json.load(open(rpath)) if os.path.exists(rpath) else {}
    rows = []
    for path in sorted(glob.glob(f"{corpus}/runs/*/*.jsonl")):
        run = os.path.basename(os.path.dirname(path))
        for line in open(path):
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                f = json.loads(line)
            except json.JSONDecodeError:
                continue
            h = fhash(f)
            v = lenient.get(h, "unjudged")
            if v == "real":
                v = strict.get(h, {}).get("verdict", "unsure")
            if rematched.get(h, "no") != "no":
                v = rematched[h]
            true = v in seeded or v == "real"
            try:
                ln = int(f.get("line") or 0)
            except (TypeError, ValueError):
                ln = 0
            rows.append({"run": run, "file": str(f.get("file")), "line": ln, "verdict": v, "true": true})
    return rows


def cluster(rows):
    """Union-find over true findings: same file, lines within 10."""
    true = [i for i, r in enumerate(rows) if r["true"]]
    parent = {i: i for i in true}

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    by_file = {}
    for i in true:
        by_file.setdefault(rows[i]["file"], []).append(i)
    for idx in by_file.values():
        idx.sort(key=lambda i: rows[i]["line"])
        for a, b in zip(idx, idx[1:]):
            if rows[b]["line"] - rows[a]["line"] <= 10:
                parent[find(a)] = find(b)
    for i in true:
        rows[i]["cluster"] = find(i)


def fit_rates(corpus):
    X, y = [], []
    for f in glob.glob(f"{corpus}/runs/*/*.json"):
        try:
            d = json.load(open(f))
        except json.JSONDecodeError:
            continue
        if "usage" in d and d.get("total_cost_usd"):
            X.append([d["usage"].get(c, 0) for c in COLS])
            y.append(d["total_cost_usd"])
    rates, *_ = np.linalg.lstsq(np.array(X, float), np.array(y, float), rcond=None)
    pred = np.array(X, float) @ rates
    err = float(np.max(np.abs(pred - y) / np.array(y)))
    return rates, len(y), err


def run_cost(corpus, run, rates):
    """(dollars, wall seconds) for a run, headless or fork."""
    rdir = f"{corpus}/runs/{run}"
    heads = glob.glob(f"{rdir}/*.json")
    if heads:
        ds = [json.load(open(f)) for f in heads]
        cost = sum(np.dot([d["usage"].get(c, 0) for c in COLS], rates) for d in ds)
        return cost, max(d.get("duration_ms", 0) for d in ds) / 1000
    txt = open(f"{rdir}/usage.txt").read()
    wall = int(re.search(r"wall=(\d+)s", txt).group(1))
    transcript = re.search(r"transcript=(\S+)", txt).group(1)
    here = os.path.dirname(os.path.abspath(__file__))
    out = subprocess.run([sys.executable, "-I", f"{here}/../scripts/usage.py", transcript, "--json"],
                         capture_output=True, text=True, check=True).stdout
    cost = sum(np.dot([a.get(c, 0) for c in COLS], rates) for a in json.loads(out))
    return cost, wall


def main():
    corpus = sys.argv[1].rstrip("/")
    rows = load(corpus)
    cluster(rows)
    # Four rates need well over four headless agents to fit; a small corpus borrows
    # the fit from a larger one: analyze.py <corpus> --rates-from <other-corpus>.
    rates_corpus = sys.argv[sys.argv.index("--rates-from") + 1].rstrip("/") if "--rates-from" in sys.argv else corpus
    rates, n, err = fit_rates(rates_corpus)
    if n < 8:
        sys.exit(f"analyze.py: only {n} headless agents to fit 4 rates on; pass --rates-from <larger corpus>")
    print(f"fitted $/Mtok on {n} headless agents (max error {100 * err:.1f}%): "
          + ", ".join(f"{c.split('_')[0] if c != 'cache_creation_input_tokens' else 'cache_write'}"
                      f"{'' if c != 'cache_read_input_tokens' else '_read'}={r * 1e6:.2f}"
                      for c, r in zip(COLS, rates)))
    runs = sorted({r["run"] for r in rows})
    issues = {run: {r["cluster"] for r in rows if r["run"] == run and r["true"]} for run in runs}
    all_issues = set().union(*issues.values())
    print(f"{len(all_issues)} distinct true issues across all runs\n")
    print(f"{'run':<28} {'finds':>5} {'true':>5} {'seeded':>6} {'distinct':>8} {'unique':>6} {'dup%':>5} {'cost':>7} {'$/issue':>8} {'wall':>6}")
    costs = {}
    for run in runs:
        mine = [r for r in rows if r["run"] == run]
        true_n = sum(r["true"] for r in mine)
        others = set().union(*(issues[o] for o in runs if o != run))
        uniq = len(issues[run] - others)
        dup = 100 * (true_n - len(issues[run])) / true_n if true_n else 0
        cost, wall = run_cost(corpus, run, rates)
        per = cost / len(issues[run]) if issues[run] else float("nan")
        seed = len({r["verdict"] for r in mine if re.fullmatch(r"D\d+", r["verdict"])})
        n_seeded = len(json.load(open(f"{corpus}/answer-key.json")))
        print(f"{run:<28} {len(mine):>5} {true_n:>5} {seed:>3}/{n_seeded:<2} {len(issues[run]):>8} {uniq:>6} {dup:>4.0f}% "
              f"${cost:>6.2f} ${per:>7.3f} {wall:>5.0f}s")
        costs[run] = (cost, wall)

    # Per arm, across replicates (run name minus its -rN suffix). Uniqueness is
    # judged against OTHER arms, so replicates of one arm don't cancel each other.
    arms = {}
    for run in runs:
        arms.setdefault(re.sub(r"-r\d+$", "", run), []).append(run)
    arm_issues = {a: set().union(*(issues[r] for r in rs)) for a, rs in arms.items()}
    print(f"\n{'arm':<26} {'n':>2} {'distinct/run':>12} {'range':>7} {'union':>5} {'unique':>6} {'$/run':>6} {'$/issue':>8} {'wall':>6}")
    for arm, rs in sorted(arms.items()):
        per_run = [len(issues[r]) for r in rs]
        others = set().union(*(arm_issues[o] for o in arms if o != arm))
        mean_cost = sum(costs[r][0] for r in rs) / len(rs)
        mean_wall = sum(costs[r][1] for r in rs) / len(rs)
        mean_n = sum(per_run) / len(rs)
        print(f"{arm:<26} {len(rs):>2} {mean_n:>12.1f} {min(per_run):>3}-{max(per_run):<3} "
              f"{len(arm_issues[arm]):>5} {len(arm_issues[arm] - others):>6} ${mean_cost:>5.2f} "
              f"${mean_cost / mean_n if mean_n else float('nan'):>7.3f} {mean_wall:>5.0f}s")

    # Equal-n comparison: union and uniqueness grow with replicate count, so compare
    # only arms with >= 2 runs, using exactly their first 2 runs.
    pair = {a: sorted(rs)[:2] for a, rs in arms.items() if len(rs) >= 2}
    if len(pair) >= 2:
        pi = {a: set().union(*(issues[r] for r in rs)) for a, rs in pair.items()}
        ptrue = {a: sum(r["true"] for r in rows if r["run"] in rs) for a, rs in pair.items()}
        print(f"\nequal n=2: {'arm':<24} {'union':>5} {'unique':>6} {'unique/10 true':>14}")
        for a in sorted(pair):
            u = len(pi[a] - set().union(*(pi[o] for o in pair if o != a)))
            print(f"           {a:<24} {len(pi[a]):>5} {u:>6} {10 * u / ptrue[a]:>14.2f}")
        print("\nshare of ROW arm's issues that COLUMN arm never finds (n=2 each):")
        names = sorted(pair)
        print(f"{'':<24}" + "".join(f"{n[:14]:>16}" for n in names))
        for a in names:
            cells = "".join(f"{100 * len(pi[a] - pi[b]) / len(pi[a]):>15.0f}%" if a != b else f"{'-':>16}"
                            for b in names)
            print(f"{a:<24}{cells}")


if __name__ == "__main__":
    main()
