---
description: Deep codebase cleanup via eight parallel subagents that inherit this session's context. Each owns one concern — dedup, type consolidation, dead code, circular deps, weak types, defensive-programming cruft, legacy paths, AI slop. Uses native Agent forks so spawns see the recon phase as live conversation, not a re-inlined brief. Forks only report; this session triages the reports and makes every edit.
---

# Code Cleanup

Recon once in this session, then fan out to eight forked subagents that inherit the conversation. The forks are read-only: each writes a report of proposed changes. This session triages all eight reports and applies the edits itself, one concern at a time. Eight writers on one working tree walk over each other, and eight worktrees are impractical, so there is one writer.

**Dependency:** none. Uses the built-in `subagent_type: "fork"` (Claude Code ≥ 2.1.229), which inherits the full conversation and the prompt cache.

**Cost note:** a fork inherits the parent model and ignores any `model` override. On an Opus main loop that means eight Opus subagents — confirm with the user before dispatching. On a ds4 profile it is eight ds4 subagents reusing an already-cached prefix, which is close to free; dispatch without asking.

## Phase 1 — Recon (this session)

Build understanding in the conversation, not in a file. The point is: everything said or read here is inherited by every fork. Don't hoard in `.tmp/`.

Work through:

1. **Languages and package managers.** Read every root manifest. Note workspace layout.
2. **Build / typecheck / test / lint commands.** From manifest + any `Makefile` / `justfile` / `turbo.json` / `nx.json`.
3. **Tree.** `tree -L 3 -I 'node_modules|dist|build|target|.venv|__pycache__'` at the root. Per-package in a monorepo.
4. **Entry points and public API.** `main`, `exports`, `bin`, `[[bin]]`, `[lib]`, framework conventions.
5. **Config surface.** tsconfig, ESLint, `ruff.toml`, `clippy.toml`, `.editorconfig`.
6. **Test layout.** Where tests live, runner, coverage tool.
7. **Tool availability.** Verify which cleanup tools are installed: `knip`, `ts-prune`, `madge`, `vulture`, `deadcode`, `cargo machete`, `cargo udeps`, `pydeps`, `depcheck`. Note which work.
8. **Landmines.** Generated code, vendored code, protobuf output — anything spawns must not touch.

Summarize aloud in the conversation. This is now part of the context every fork will see.

## Phase 2 — Fan out (forks report, never edit)

`mkdir -p .tmp/code-cleanup/reports`, then dispatch all eight forks **in a single message** so they run concurrently.

Spawn template, repeated once per mandate (`NN` = 01…08):

```yaml
Agent:
  subagent_type: "fork"
  name: "cleanup-NN-<concern>"
  description: "<concern> cleanup report"
  prompt: |
    <mandate text>

    You inherited this session's recon phase — the tree, the build/typecheck/test commands,
    the confirmed tool availability, and the landmine list are all above. Do not re-derive them.

    You are read-only. Do not edit, create, move or delete any file except your report.
    Seven other forks are reading the same tree, and the main session applies every change.

    Your plain-text output is NOT visible to the orchestrator. Write your full report to
    `.tmp/code-cleanup/reports/fork-NN.md` — that file is authoritative. One entry per finding:
    - location: path:line (every site, not a sample)
    - evidence: the grep output, AST match or tool output that proves it
    - proposed change: concrete enough to apply without re-investigating (a diff when short)
    - confidence: high | medium | low, and what could break (dynamic wiring, reflection,
      public API, generated code)
    - depends on / conflicts with: other concerns this change touches, if you can see them
    Then items you looked at and rejected, with the reason. End the file with one line: WROTE_REPORT.
```

The eight mandates:

1. **Deduplicate.** Find repeated logic across the codebase you've seen. Propose DRY only where it cuts real complexity — never abstraction for its own sake; leave three-line repetition alone.
2. **Consolidate types.** Find type definitions duplicated across files or packages. Propose one source of truth for each shared shape and list every import that must change.
3. **Dead code.** Run the tools we confirmed are installed. Find unreferenced exports, files, and dependencies. Grep the full tree — tests, configs, dynamic imports included — before calling anything dead.
4. **Circular dependencies.** Run madge/pydeps/equivalent. For each cycle, propose the break: invert a dependency or extract the shared piece. Never propose masking it with lazy imports.
5. **Weak types.** Find every any/unknown/object/{}/Python Any/Go interface{}/Rust Box<dyn Any>. Read call sites and upstream types; propose the real type for each.
6. **Defensive programming.** Find every try/catch and equivalent. Keep only those handling real external input, documented failure modes, or caller-uncrossable boundaries. Propose removing empty catches, silent fallbacks, speculative guards.
7. **Legacy paths.** Find deprecated code, compat shims, fallback branches, `// TODO: remove after X` that outlived X, feature flags long since defaulted. Propose the single canonical path.
8. **AI slop.** Find narration comments, "replaced old Y with new Z" notes, commented-out code, obvious-from-code comments, stub scaffolds. Keep comments that explain why, constraints, or non-obvious invariants; propose rewrites of those for a new reader, with no references to prior versions.

Each fork starts with the full recon phase as inherited context and reuses the cached prompt prefix, so the marginal cost of the eighth fork is far below the first. Forks run in the background by default; wait for all eight before triaging. The report file existing and non-empty is the delivery signal — a fork that dies silently never returns, so check the files rather than waiting indefinitely.

## Phase 3 — Triage, then apply (this session is the only writer)

1. Read every file in `.tmp/code-cleanup/reports/fork-NN.md`. Full text — do not grep-skim.
2. Build one change list. Merge findings that touch the same code (dead code and legacy paths overlap often, as do dedup and type consolidation), and where two proposals conflict, keep the more conservative one.
3. Triage each item: **apply** (high confidence, evidence holds when you re-check it), **ask** (anything that could break dynamic wiring, reflection, or a public API — WordPress hooks, Django signals, Rails autoload), or **skip** (weak evidence). Show the user the ask items before touching them.
4. Apply in an order that keeps later edits valid: legacy paths and dead code first (deletions shrink what the rest must touch), then circular dependencies, type consolidation, dedup, weak types, defensive code, and AI slop last.
5. After each concern, run typecheck and tests. Green: commit it as `cleanup(<concern>): …`. Red: fix it or revert that concern's batch before moving on.
6. List the skipped and medium/low-confidence findings as a follow-up checklist.
7. Delete `.tmp/code-cleanup/`.

## Rules

- **Forks never write code.** Their only output is the report. A fork that edits the tree breaks the other seven's view of it.
- **Scope is the mandate.** Fork 1 doesn't report on types. Fork 5 doesn't hunt dead code.
- **Evidence before edits.** Findings without grep output, AST matches, or tool output don't touch code, and this session re-checks the evidence before applying.
- **Prove every fix.** Typecheck and tests pass after each concern's batch, or the batch reverts.

## Fallback: no fork available

Fork is unavailable in two cases: headless runs (below) and Claude Code older than 2.1.229. Use `subagent_type: "general-purpose"` with a byte-identical prefix across the 8 parallel spawns. The prefix must inline the full brief and protocol, because a general-purpose subagent sees none of the conversation. Stagger spawn #1 until streaming confirms cache commit, then launch 2–8 in one message. Inferior — each spawn re-reads ambient context the recon phase already covered — but it works everywhere.

The same fallback applies under `claude --print` and anywhere `--no-session-persistence` is set: fork needs a live session transcript to snapshot, so headless callers must inline the brief.
