#!/usr/bin/env python3
"""Token and wall-clock usage of the subagents in a Claude Code session.

    usage.py <session-id | path/to/<session-id>.jsonl | path/to/<session-id>/> [--json]

Reads <session>/subagents/agent-*.jsonl and their .meta.json sidecars, plus the
parent transcript. A transcript writes the same usage record once per streamed
chunk of a response, so records are deduplicated by message.id (last one wins)
before summing; summing raw lines overcounts several times over.

Columns: requests, input (uncached), cache_create, cache_read, output tokens,
cache-hit ratio (cache_read / all input), and wall-clock from the agent's first
to last record.
"""
import glob
import json
import os
import sys
from datetime import datetime

FIELDS = ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens")


def find_session_dir(arg):
    if os.path.isdir(arg):
        return arg.rstrip("/")
    if arg.endswith(".jsonl") and os.path.isfile(arg):
        return arg[: -len(".jsonl")]
    hits = glob.glob(os.path.expanduser(f"~/.claude*/projects/*/{arg}"))
    if not hits:
        sys.exit(f"usage.py: no session directory for {arg}")
    return hits[0]


def parse_ts(ts):
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))


def summarize(path):
    """Usage totals for one transcript, deduplicated by message id."""
    by_id, first, stamps, model = {}, {}, [], None
    with open(path) as f:
        for line in f:
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            if rec.get("timestamp"):
                stamps.append(rec["timestamp"])
            msg = rec.get("message") or {}
            if rec.get("type") != "assistant" or not msg.get("usage"):
                continue
            by_id[msg.get("id") or id(rec)] = msg["usage"]
            first = first or msg["usage"]
            model = msg.get("model") or model
    totals = {k: sum(u.get(k, 0) for u in by_id.values()) for k in FIELDS}
    totals["requests"] = len(by_id)
    # The first request shows what the agent started from: a fork opens with a big
    # cache read (the inherited parent prefix), a fresh agent with a big cache write.
    totals["first_read"] = first.get("cache_read_input_tokens", 0)
    totals["first_create"] = first.get("cache_creation_input_tokens", 0)
    totals["model"] = model
    totals["wall_s"] = (parse_ts(max(stamps)) - parse_ts(min(stamps))).total_seconds() if stamps else 0
    totals["start"] = min(stamps) if stamps else None
    return totals


def hit_ratio(t):
    seen = t["input_tokens"] + t["cache_creation_input_tokens"] + t["cache_read_input_tokens"]
    return t["cache_read_input_tokens"] / seen if seen else 0.0


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    sdir = find_session_dir(sys.argv[1])
    rows = []
    for path in sorted(glob.glob(f"{sdir}/subagents/agent-*.jsonl")):
        meta_path = path[: -len(".jsonl")] + ".meta.json"
        meta = json.load(open(meta_path)) if os.path.exists(meta_path) else {}
        t = summarize(path)
        t.update(agent=os.path.basename(path)[6:-6], type=meta.get("agentType", "?"),
                 fork=bool(meta.get("isFork")), description=meta.get("description", ""))
        rows.append(t)
    if os.path.exists(sdir + ".jsonl"):
        parent = summarize(sdir + ".jsonl")
        parent.update(agent="(parent)", type="main", fork=False, description="main session")
        rows.insert(0, parent)

    if "--json" in sys.argv:
        print(json.dumps(rows, indent=1))
        return
    head = (f"{'type':<16} {'req':>4} {'c_create':>9} {'c_read':>10} {'output':>8} {'hit%':>5} "
            f"{'1st_read':>9} {'1st_create':>10} {'wall':>7}  description")
    print(head)
    for t in rows:
        print(f"{t['type']:<16} {t['requests']:>4} {t['cache_creation_input_tokens']:>9} "
              f"{t['cache_read_input_tokens']:>10} {t['output_tokens']:>8} {100 * hit_ratio(t):>4.0f}% "
              f"{t['first_read']:>9} {t['first_create']:>10} {t['wall_s']:>6.0f}s  {t['description'][:40]}")


if __name__ == "__main__":
    main()
