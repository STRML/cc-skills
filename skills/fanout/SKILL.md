---
name: fanout
description: Parallel deep review of a codebase. Map the repo once in this session, then fork N subagents that inherit that map and each look at the code by a different method (data flow, invariants, parity, boundaries, ...). Forks only report; this session deduplicates, verifies and ranks the findings. Use when the user asks for a thorough bug hunt, deep review or audit of a repo or subsystem, or says "fanout" or "fan out a review", and the code fits in context.
argument-hint: "[N lenses, default 4] [path or subsystem]"
---

# /fanout: map once, fork by method, triage in one place

```
recon (this session, facts only) ─▶ map of the code, now in context
  ├─▶ fork 1 alone      ─▶ warms the prompt cache with that map
  └─▶ forks 2..N, next message ─▶ read the map from cache, one method each
each fork ─▶ .tmp/fanout/<run>/<lens>.jsonl   (read-only, never edits)
this session ─▶ cluster duplicates ─▶ verify each against the code ─▶ ranked report
```

Measured on one repo with Sonnet (`bench/README.md`): 4 staggered forks found 2.7× the real issues of a single agent at about the same cost per issue, and cost 59% of the same lenses run as fresh agents. More coverage comes from more forked lenses or a second forked batch; fresh agents found no more issues per finding than forks did.

## Cost check first

A fork inherits this session's model; the `model` parameter is ignored. On an expensive model, N forks cost N agents' output at that rate, though their input mostly comes from cache. Say the model and N before dispatching on Opus-class models.

## Phase 1: recon (this session)

Build the map in the conversation, because every fork inherits exactly what is here.

1. Read the README, the manifest (`package.json`, `pyproject.toml`, `Cargo.toml`, ...) and the build, typecheck and test commands.
2. Read every source file in scope with the Read tool, so each fork starts with the code itself in its cached prefix. Measured at ~70K tokens of source. Above roughly 150K, narrow the scope to the subsystem the user named, or to the changed files plus what they import. Larger repos are untested.
3. Note generated, vendored and test-fixture code the forks must ignore.
4. **Facts only.** Do not write judgments ("X looks solid", "Y is probably the bug") in this phase. Whatever is written here is inherited by every fork and anchors all of them on the same guess.

## Phase 2: fan out with a staggered launch

`mkdir -p .tmp/fanout/<run>`. Take the first N lenses from `presets/review.json`. Default N=4. N=8 found 27% more issues for 46% more cost, so use it when coverage matters more than budget. Below N=3, forking costs the same as fresh agents.

1. Launch **lens 1 alone**: one Agent call, `subagent_type: "fork"`, in the background.
2. In your **next** message, launch lenses 2..N together.

Launching all N in one message makes every fork miss the cache: none of the siblings' cache writes has committed yet, so each rebuilds the whole prefix. Measured: launched together, each fork's first request wrote ~154K cache tokens; staggered, forks 2..N each wrote under 1K.

Fork prompt, with the lens filled in:

```
Audit this code for real bugs: behavior that is wrong for a user. Not style, not refactors.
You already have the source in context from the recon; read more only if you need to.
Your method: <LENS BRIEF>
You are read-only: do not edit, create or delete any file except your report.
Write ONLY JSON lines to .tmp/fanout/<run>/<LENS ID>.jsonl with the Write tool, one per finding:
{"file": "...", "line": <n>, "title": "<short>", "why": "<what goes wrong, and when>"}
At most 15 findings, strongest first. Your text output is not visible; only the file counts.
```

The report file existing and non-empty is the delivery signal. A fork that dies silently never reports back, so check the files instead of waiting indefinitely.

## Phase 3: triage (this session is the only writer)

1. Read every report in full.
2. Cluster duplicates: two findings are one issue when they describe the same behavior at the same place. Expect a third or more of findings to be repeats across lenses.
3. Verify each issue by reading the cited code. Drop it if the behavior is intended, guarded elsewhere, unreachable, or a style concern. Keep it only if you can state a concrete scenario: the input or event sequence, the wrong result and the right one.
4. Rank by user impact and report: one line per verified issue with `path:line`, the scenario, and which lenses found it (agreement across methods is evidence; a single lens is not a demerit).
5. Make edits only if the user asks for fixes. Then apply one issue at a time and run the tests after each.
6. Delete `.tmp/fanout/<run>/` when done.

## Rules

- Forks never edit. A fork that writes to the tree changes what the other forks are reading.
- Lenses diverge by method, not topic. Method lenses found 1.8-2.0 issues no other configuration found per 10 true findings; topic splits ("look at the hooks", "look at the math") found 1.4.
- No fork available (`claude -p`, `--no-session-persistence`, Claude Code before 2.1.229): run the lenses as general-purpose subagents with the brief inlined. They re-read the code themselves: at N=4 that measured 1.7× the cost of the forked run, recon included ($3.08 vs $1.82 on Sonnet).
