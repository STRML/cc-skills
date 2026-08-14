---
description: Deep codebase cleanup via eight parallel subagents that inherit this session's context. Each owns one concern — dedup, type consolidation, dead code, circular deps, weak types, defensive-programming cruft, legacy paths, AI slop. Uses native Agent forks so spawns see the recon phase as live conversation, not a re-inlined brief.
---

# Code Cleanup

Recon once in this session, then fan out to eight forked subagents that inherit the conversation. Reconcile their reports.

**Dependency:** none. Uses the built-in `subagent_type: "fork"` (Claude Code ≥ 2.1.229), which inherits the full conversation and the prompt cache.

**Cost note:** a fork inherits the parent model and ignores any `model` override. On an Opus 5 main loop that means eight Opus subagents — confirm with the user before dispatching. On a ds4 profile it is eight ds4 subagents reusing an already-cached prefix, which is close to free; dispatch without asking.

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

## Phase 2 — Ask mode, then fan out

Ask the user:

- **Edit mode** — forks apply high-confidence fixes, run typecheck/tests after each batch, revert on failure. Risk: 8 spawns sharing one working tree can create conflicts; an aggressive delete can break dynamic wiring (WordPress hooks, Django signals, Rails autoload).
- **Dry-run mode** — forks produce evidence-backed reports only. Safer for fragile codebases or first-time use.

Default to dry-run if unclear.

Then `mkdir -p .tmp/code-cleanup/reports` and dispatch all eight forks **in a single message** so they run concurrently.

Spawn template, repeated once per mandate (`NN` = 01…08):

```yaml
Agent:
  subagent_type: "fork"
  name: "cleanup-NN-<concern>"
  description: "<concern> cleanup"
  prompt: |
    MODE=<edit|dry-run>. <mandate text>

    You inherited this session's recon phase — the tree, the build/typecheck/test commands,
    the confirmed tool availability, and the landmine list are all above. Do not re-derive them.

    Your plain-text output is NOT visible to the orchestrator. Write your full report to
    `.tmp/code-cleanup/reports/fork-NN.md` — that file is authoritative. Cover: assessment,
    changes made (or proposed, in dry-run), items skipped with reasons, and follow-ups for the
    main session. End the file with one line: WROTE_REPORT.
```

Substitute `edit` or `dry-run` for `<edit|dry-run>` in every spawn before dispatching.

The eight mandates:

1. **Deduplicate.** Find repeated logic across the codebase you've seen. Apply DRY only where it cuts real complexity — never abstraction for its own sake; leave three-line repetition alone.
2. **Consolidate types.** Find type definitions duplicated across files or packages. Move shared shapes to one source of truth; update every import.
3. **Dead code.** Run the tools we confirmed are installed. Remove unreferenced exports, files, and dependencies. Grep the full tree — tests, configs, dynamic imports included — before cutting.
4. **Circular dependencies.** Run madge/pydeps/equivalent. Break every cycle by inverting a dependency or extracting the shared piece; do not mask with lazy imports.
5. **Weak types.** Find every any/unknown/object/{}/Python Any/Go interface{}/Rust Box<dyn Any>. Read call sites and upstream types; replace with real types. Typecheck must end green.
6. **Defensive programming.** Find every try/catch and equivalent. Keep only those handling real external input, documented failure modes, or caller-uncrossable boundaries. Delete empty catches, silent fallbacks, speculative guards.
7. **Legacy paths.** Find deprecated code, compat shims, fallback branches, `// TODO: remove after X` that outlived X, feature flags long since defaulted. Delete. Every path should be the single canonical path.
8. **AI slop.** Remove narration comments, "replaced old Y with new Z" notes, commented-out code, obvious-from-code comments, stub scaffolds. Keep comments that explain why, constraints, or non-obvious invariants — rewrite them for a new reader, with no references to prior versions.

Each fork starts with the full recon phase as inherited context and reuses the cached prompt prefix, so the marginal cost of the eighth fork is far below the first. Forks run in the background by default; wait for all eight before reconciling. The report file existing and non-empty is the delivery signal — a fork that dies silently never returns, so check the files rather than waiting indefinitely.

## Phase 3 — Reconcile

1. Read every file in `.tmp/code-cleanup/reports/fork-NN.md`. Full text — do not grep-skim.
2. Surface each fork's findings inline for the user.
3. Resolve overlapping edits if edit mode ran; prefer the more conservative change.
4. Run full typecheck and test suite once more.
5. Commit per concern: `cleanup(dedup): …`, `cleanup(types): …`, etc.
6. List medium- and low-confidence findings as a follow-up checklist.
7. Delete `.tmp/code-cleanup/`.

## Rules

- **Scope is the mandate.** Fork 1 doesn't fix types. Fork 5 doesn't remove dead code.
- **Evidence before edits.** Findings without grep output, AST matches, or tool output don't touch code.
- **High confidence only** (edit mode). Medium and low go in the report.
- **Prove every fix.** Typecheck and tests pass after each batch, or the batch reverts.
- **Shared tree.** In edit mode, 8 spawns edit one working copy. Expect conflicts; reconcile is not optional.

## Fallback: Claude Code older than 2.1.229

`subagent_type: "fork"` does not exist before 2.1.229. Use `subagent_type: "general-purpose"` with a byte-identical prefix across the 8 parallel spawns. The prefix must inline the full brief and protocol, because a general-purpose subagent sees none of the conversation. Stagger spawn #1 until streaming confirms cache commit, then launch 2–8 in one message. Inferior — each spawn re-reads ambient context the recon phase already covered — but it works everywhere.

The same fallback applies under `claude --print` and anywhere `--no-session-persistence` is set: fork needs a live session transcript to snapshot, so headless callers must inline the brief.
