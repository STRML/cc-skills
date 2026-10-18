#!/usr/bin/env python3
"""Blind-judge every finding from every benchmark run, then score the arms.

    judge.py <corpus-dir>            judge unjudged findings, then score
    judge.py <corpus-dir> --score    score only, from the existing verdicts

<corpus-dir> holds answer-key.json, target/, and runs/<run>/<agent>.jsonl.
Findings are pooled, deduplicated by exact text, shuffled and stripped of their
run labels before Codex sees them, so the judge cannot favor an arm. Verdicts are
cached in <corpus-dir>/verdicts.json; reruns judge only new findings.

Verdict per finding: "D<n>" (matches that seeded defect), "real" (a different,
genuine bug), "not-a-bug", or "unsure".
"""
import glob
import hashlib
import json
import os
import random
import subprocess
import sys
import tempfile

BATCH = 60
# Findings a judge call failed to return a verdict for. They are never stored (a
# rerun retries them), and the script exits 2 if any remain.
MISSED = []
JUDGE_MODEL = os.environ.get("JUDGE_MODEL", "gpt-6-luna")


def first_json_object(raw):
    """The first complete JSON object in a model reply; text after it is ignored."""
    start = raw.find("{")
    if start < 0:
        return {}
    try:
        obj, _ = json.JSONDecoder().raw_decode(raw[start:])
    except json.JSONDecodeError:
        return {}
    return obj if isinstance(obj, dict) else {}


def load_findings(corpus):
    """[(run, agent, finding-dict, key)] for every parseable finding line."""
    out = []
    for path in sorted(glob.glob(f"{corpus}/runs/*/*.jsonl")):
        run = os.path.basename(os.path.dirname(path))
        agent = os.path.basename(path)[:-6]
        for line in open(path):
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                f = json.loads(line)
            except json.JSONDecodeError:
                continue
            text = f"{f.get('file')}:{f.get('line')} {f.get('title')} — {f.get('why')}"
            out.append((run, agent, f, hashlib.sha1(text.encode()).hexdigest()[:12], text))
    return out


def judge_batch(corpus, key, items):
    """Ask Codex for a verdict on each (id, text) item. Returns {id: verdict}."""
    defects = "\n".join(
        f"{d['id']}: {d['fix_subject']} (files: {', '.join(d['files'])})\n  {' '.join(d['hunks'][:6])}"
        for d in key)
    listing = "\n".join(f"{i}: {t}" for i, t in items)
    prompt = f"""You are judging bug reports against a repository in the current directory, read-only.
The repository has these known seeded defects (the fix that was reverted, and where):
{defects}

For each finding below, decide:
- "D<n>" if it describes that seeded defect (same file and the same wrong behavior; wording may differ),
- "real" if it is a genuine bug that is not one of the seeded defects (check the code to confirm),
- "not-a-bug" if the code is actually fine,
- "unsure" if you cannot tell.
Open the cited code before deciding. Be strict: a vague report that only names the right file is not a match.

Findings:
{listing}

Reply with ONLY a JSON object mapping each finding id to its verdict, e.g. {{"f1": "D3", "f2": "not-a-bug"}}."""
    with tempfile.NamedTemporaryFile("r", suffix=".txt", delete=False) as last:
        last_path = last.name
    subprocess.run(["codex", "exec", "-s", "read-only", "-m", JUDGE_MODEL,
                    "-C", f"{corpus}/target", "-o", last_path, prompt],
                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    raw = open(last_path).read()
    os.unlink(last_path)
    return first_json_object(raw)


def strict_batch(corpus, items):
    """Re-judge 'real' verdicts. A finding stays real only with a concrete repro."""
    listing = "\n".join(f"{i}: {t}" for i, t in items)
    prompt = f"""You are a strict senior maintainer of the library in the current directory (read-only).
Each finding below was claimed to be a genuine bug. Most such claims about mature libraries are wrong:
the behavior is intended, guarded elsewhere, unreachable, or only a style concern.

For each finding, open the cited code and the code around it, then decide:
- "real" ONLY if you can state a concrete scenario: a specific input, prop combination or event
  sequence, the wrong result it produces, and the correct result. It must be reachable through
  the public API.
- "not-a-bug" if it is intended, guarded elsewhere, unreachable, or a style or robustness nit.
- "unsure" if you cannot confirm either way.

Findings:
{listing}

Reply with ONLY a JSON object mapping each finding id to {{"verdict": "...", "scenario": "<one line, or empty>"}}."""
    with tempfile.NamedTemporaryFile("r", suffix=".txt", delete=False) as last:
        last_path = last.name
    subprocess.run(["codex", "exec", "-s", "read-only", "-m", JUDGE_MODEL,
                    "-C", f"{corpus}/target", "-o", last_path, prompt],
                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    raw = open(last_path).read()
    os.unlink(last_path)
    return first_json_object(raw)


def strict(corpus, findings, verdicts):
    """Second, stricter pass over every 'real' verdict; results in verdicts-strict.json."""
    spath = f"{corpus}/verdicts-strict.json"
    done = json.load(open(spath)) if os.path.exists(spath) else {}
    text = {h: t for _, _, _, h, t in findings}
    todo = [(h, text[h]) for h, v in verdicts.items() if v == "real" and h not in done and h in text]
    for i in range(0, len(todo), 20):
        chunk = todo[i:i + 20]
        ids = {f"f{j}": h for j, (h, _) in enumerate(chunk)}
        got = strict_batch(corpus, [(fid, text[h]) for fid, h in ids.items()])
        for fid, h in ids.items():
            v = got.get(fid)
            if not v:
                MISSED.append(h)  # the call failed or skipped it: leave it for a rerun
                continue
            done[h] = v if isinstance(v, dict) else {"verdict": str(v), "scenario": ""}
        json.dump(done, open(spath, "w"), indent=1)
        print(f"strict {min(i + 20, len(todo))}/{len(todo)}", file=sys.stderr)
    return {h: (done[h].get("verdict", "unsure") if v == "real" and h in done else v)
            for h, v in verdicts.items()}


def rematch(corpus, findings, key):
    """Re-check every finding in a seeded file against the real fix diffs.

    The first pass only saw each defect's subject and hunk headers, which was too
    little to match on: hand checks found findings that named a seeded bug outright
    filed as "real". Results go to verdicts-rematch.json: {hash: "D<n>" | "no"}.
    """
    rpath = f"{corpus}/verdicts-rematch.json"
    done = json.load(open(rpath)) if os.path.exists(rpath) else {}
    by_file = {}
    for d in key:
        for f in d["files"]:
            by_file.setdefault(f, []).append(d)
    groups = {}
    for _, _, f, h, t in findings:
        if f.get("file") in by_file and h not in done:
            groups.setdefault(f.get("file"), {})[h] = t
    for fname, items in groups.items():
        defects = "\n\n".join(f"{d['id']}: {d['fix_subject']}\n{d['fix_diff']}" for d in by_file[fname])
        pairs = list(items.items())
        for i in range(0, len(pairs), 30):
            chunk = pairs[i:i + 30]
            ids = {f"f{j}": h for j, (h, _) in enumerate(chunk)}
            listing = "\n".join(f"{fid}: {items[h]}" for fid, h in ids.items())
            prompt = f"""The repository in the current directory contains seeded bugs in {fname}. Each was made by
reverting a fix. Below is each fix's diff: the repository has the '-' side (the bug); the '+' side is the fix.

{defects}

For each finding, answer the defect id if the finding describes the bug that defect's fix repairs (same
behavior; it may describe a symptom or the cause, in different words), or "no" if it describes something else.

Findings:
{listing}

Reply with ONLY a JSON object mapping each finding id to "D<n>" or "no"."""
            with tempfile.NamedTemporaryFile("r", suffix=".txt", delete=False) as last:
                last_path = last.name
            subprocess.run(["codex", "exec", "-s", "read-only", "-m", JUDGE_MODEL,
                            "-C", f"{corpus}/target", "-o", last_path, prompt],
                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           check=False)
            raw = open(last_path).read()
            os.unlink(last_path)
            got = first_json_object(raw)
            for fid, h in ids.items():
                if fid not in got:
                    MISSED.append(h)
                    continue
                done[h] = got[fid]
            json.dump(done, open(rpath, "w"), indent=1)
        print(f"rematched {fname}: {len(pairs)} findings", file=sys.stderr)
    return done


def judge(corpus, findings, key):
    vpath = f"{corpus}/verdicts.json"
    verdicts = json.load(open(vpath)) if os.path.exists(vpath) else {}
    todo = {h: t for _, _, _, h, t in findings if h not in verdicts}
    items = list(todo.items())
    random.Random(0).shuffle(items)
    for i in range(0, len(items), BATCH):
        chunk = items[i:i + BATCH]
        ids = {f"f{j}": h for j, (h, _) in enumerate(chunk)}
        got = judge_batch(corpus, key, [(fid, todo[h]) for fid, h in ids.items()])
        for fid, h in ids.items():
            if fid not in got:
                MISSED.append(h)
                continue
            verdicts[h] = got[fid]
        json.dump(verdicts, open(vpath, "w"), indent=1)
        print(f"judged {min(i + BATCH, len(items))}/{len(items)}", file=sys.stderr)
    return verdicts


def score(corpus, findings, verdicts, key):
    runs = {}
    for run, agent, _, h, _ in findings:
        runs.setdefault(run, []).append((agent, verdicts.get(h, "unjudged")))
    seeded = {d["id"] for d in key}
    found_by = {}
    rows = []
    for run, items in sorted(runs.items()):
        hit = {v for _, v in items if v in seeded}
        found_by[run] = hit
        true_n = sum(1 for _, v in items if v in seeded or v == "real")
        dup = sum(1 for _, v in items if v in seeded) - len(hit)
        rows.append((run, len(items), len(hit), true_n, sum(1 for _, v in items if v == "real"),
                     sum(1 for _, v in items if v == "not-a-bug"), dup))
    print(f"{'run':<26} {'finds':>5} {'recall':>7} {'precision':>9} {'real-other':>10} {'false':>5} {'dup':>4}  unique")
    for run, n, hit, true_n, real, false, dup in rows:
        others = set().union(*(found_by[r] for r in found_by if r != run)) if len(found_by) > 1 else set()
        unique = sorted(found_by[run] - others, key=lambda d: int(d[1:]))
        print(f"{run:<26} {n:>5} {hit:>3}/{len(seeded):<3} {100 * true_n / n if n else 0:>8.0f}% "
              f"{real:>10} {false:>5} {dup:>4}  {','.join(unique) or '-'}")


def main():
    corpus = sys.argv[1].rstrip("/")
    key = json.load(open(f"{corpus}/answer-key.json"))
    findings = load_findings(corpus)
    if "--score" in sys.argv:
        verdicts = json.load(open(f"{corpus}/verdicts.json"))
    else:
        verdicts = judge(corpus, findings, key)
    if "--strict" in sys.argv:
        verdicts = strict(corpus, findings, verdicts)
    if "--rematch" in sys.argv:
        hits = rematch(corpus, findings, key)
        verdicts = {h: (hits[h] if hits.get(h, "no") != "no" else v) for h, v in verdicts.items()}
    score(corpus, findings, verdicts, key)
    if MISSED:
        print(f"judge.py: {len(set(MISSED))} finding(s) got no verdict (failed or skipped judge calls); "
              "rerun to retry them", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
