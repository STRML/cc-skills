---
name: fanout
description: Parallel deep pass over a codebase or a change set, driven by a preset. Map the code once in this session, then fork N subagents that inherit that map and each look by a different method or concern. Forks only report; this session deduplicates, verifies, and either ranks the findings or applies them. Presets - review (bug hunt), cleanup (dead code, dedup, types, cycles, slop; powers /code-cleanup), simplify (a diff or PR), security (vulnerability audit). Use when the user asks for a thorough bug hunt, deep review, audit, security review, codebase cleanup, or to simplify a large change, or says "fanout" or "fan out", and the code fits in context.
argument-hint: "[review|cleanup|simplify|security] [N lenses] [path, subsystem or diff base]"
---

# /fanout: map once, fork by method, triage in one place

```
recon (this session, facts only) ─▶ map of the code, now in context
  ├─▶ fork 1 alone      ─▶ warms the prompt cache with that map
  └─▶ forks 2..N, next message ─▶ read the map from cache, one lens each
each fork ─▶ .tmp/fanout/<run>/<lens>.jsonl   (read-only, never edits)
this session ─▶ cluster duplicates ─▶ verify against the code ─▶ rank, or apply in order
```

Measured on one repo with Sonnet (`bench/README.md`): 4 staggered forks found 2.7× the real issues of a single agent at about the same cost per issue, and cost 59% of the same lenses run as fresh agents. More coverage comes from more forked lenses or a second forked batch; fresh agents found no more issues per finding than forks did.

## Presets

The first argument picks a preset from `presets/`; the default is `review`. Read the preset file before Phase 1: every field below comes from it.

| Preset | Scope | Default N | Triage | Status |
|---|---|---|---|---|
| `review` | repo or subsystem | 4 of 12 | verify and rank | measured |
| `cleanup` | repo | 8 of 8 | apply, commit per concern | unbenchmarked |
| `simplify` | a diff | 5 of 5 | apply | unbenchmarked |
| `security` | repo or subsystem | 4 of 6 | verify and rank | unbenchmarked |

| Field | Used in |
|---|---|
| `scope` | Phase 1: `repo` reads the source in scope, `diff` reads the change set and what it touches |
| `recon_extra` | Phase 1: preset-specific facts to collect |
| `default_n`, `lenses` | Phase 2: a run with N lenses takes the first N |
| `task`, `report_line`, `max_findings` | Phase 2: the fork prompt |
| `triage`, `keep_if`, `apply_order` | Phase 3 |

## Cost check first

A fork inherits this session's model; the `model` parameter is ignored. On an expensive model, N forks cost N agents' output at that rate, though their input mostly comes from cache. On Opus-class models, say the preset, model and N and confirm before dispatching. On a cheap profile (ds4, Haiku) dispatch without asking.

## Phase 1: recon (this session)

Build the map in the conversation, because every fork inherits exactly what is here.

1. Read the README, the manifest (`package.json`, `pyproject.toml`, `Cargo.toml`, ...) and the build, typecheck and test commands.
2. Scope `repo`: read every source file in scope with the Read tool, so each fork starts with the code itself in its cached prefix. Measured at ~70K tokens of source. Above roughly 150K, narrow the scope to the subsystem the user named, or to the changed files plus what they import. Larger repos are untested. Scope `diff`: follow the preset's `recon_extra`, which reads the diff and the code around it.
3. Do each step in the preset's `recon_extra`.
4. Note generated, vendored and test-fixture code the forks must ignore.
5. **Facts only.** Do not write judgments ("X looks solid", "Y is probably the bug") in this phase. Whatever is written here is inherited by every fork and anchors all of them on the same guess.

## Phase 2: fan out with a staggered launch

`mkdir -p .tmp/fanout/<run>`, where `<run>` names the preset and the date. Take the first N lenses from the preset; N defaults to its `default_n`. For `review`, N=8 found 27% more issues for 46% more cost, so use it when coverage matters more than budget. Below N=3, forking costs the same as fresh agents.

1. Launch **lens 1 alone**: one Agent call, `subagent_type: "fork"`, in the background.
2. In your **next** message, launch lenses 2..N together.

Launching all N in one message makes every fork miss the cache: none of the siblings' cache writes has committed yet, so each rebuilds the whole prefix. Measured: launched together, each fork's first request wrote ~154K cache tokens; staggered, forks 2..N each wrote under 1K.

Fork prompt, with the preset's fields and the lens filled in:

```
<TASK>
You already have the source in context from the recon; read more only if you need to.
Your method: <LENS BRIEF>
You are read-only: do not edit, create or delete any file except your report.
Write ONLY JSON lines to .tmp/fanout/<run>/<LENS ID>.jsonl with the Write tool, one per finding:
<REPORT LINE>
At most <MAX FINDINGS> findings, strongest first. Your text output is not visible; only the file counts.
```

The report file existing and non-empty is the delivery signal. A fork that dies silently never reports back, so check the files instead of waiting indefinitely.

## Phase 3: triage (this session is the only writer)

1. Read every report in full.
2. Cluster duplicates: two findings are one item when they describe the same behavior or change at the same place. Expect a third or more of findings to be repeats across lenses. Where two proposed changes conflict, keep the more conservative one.
3. Verify each item by reading the cited code. Drop it if the behavior is intended, guarded elsewhere, unreachable, or outside the preset's task. Keep it only if the preset's `keep_if` holds.
4. Then follow the preset's `triage`.

**`verify`** (review, security): rank by impact and report one line per item with `path:line`, the scenario, and which lenses found it. Agreement across methods is evidence; a single lens is not a demerit. Make edits only if the user asks for fixes, then apply one item at a time and run the tests after each.

**`apply`** (cleanup, simplify):

1. Sort each item into **apply** (high confidence, evidence holds on re-check), **ask** (could break dynamic wiring, reflection or a public API: framework hooks, signals, autoloading, exported names), or **skip** (weak evidence). Show the user the ask items before touching them.
2. Apply lens by lens in the preset's `apply_order`. The order keeps later edits valid: deletions first, because they shrink what the rest must touch.
3. After each lens, run typecheck and tests. Green: commit it as `<preset>(<lens>): ...`. Red: fix it, or revert that lens's batch before moving on.
4. End with the skipped and medium- or low-confidence items as a follow-up checklist.

Delete `.tmp/fanout/<run>/` when done.

## Rules

- Forks never edit. A fork that writes to the tree changes what the other forks are reading, and N writers on one working tree walk over each other.
- Scope is the lens. A fork reports only within its lens; overlap is cleaned up in triage.
- Lenses diverge by method, not topic. In `review`, method lenses found 1.8-2.0 issues no other configuration found per 10 true findings; topic splits ("look at the hooks", "look at the math") found 1.4. `cleanup`'s lenses are concerns rather than methods, because each concern has its own apply step.
- No fork available (`claude -p`, `--no-session-persistence`, Claude Code before 2.1.229): run the lenses as general-purpose subagents with the recon summary and the fork prompt inlined, byte-identical up to the lens, so they share a cached prefix. Launch the first alone, then the rest, as above. They re-read the code themselves: at N=4 that measured 1.7× the cost of the forked run, recon included ($3.08 vs $1.82 on Sonnet).
