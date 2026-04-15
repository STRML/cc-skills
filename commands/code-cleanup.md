---
description: Deep codebase cleanup. A single recon pass builds a shared context brief, then eight parallel subagents each own one concern — dedup, type consolidation, dead code, circular deps, weak types, defensive-programming cruft, legacy paths, AI slop. Shared preamble means all eight spawns hit the prompt cache.
---

# Code Cleanup

One recon pass, then eight parallel subagents. Shared context first — saves tokens, keeps findings aligned.

## Phase 1 — Recon (main session, do this once)

Build the shared brief. Do not skip items; missing context forces subagents to re-explore. Write the brief to `.tmp/code-cleanup/brief.md`.

Gather:

1. **Languages and package managers.** Read every root manifest (`package.json`, `pyproject.toml`, `Cargo.toml`, `go.mod`, etc.). Note workspace layout.
2. **Build, typecheck, test, lint commands.** From the manifest and any `Makefile` / `justfile` / `turbo.json` / `nx.json`.
3. **Tree.** `tree -L 3 -I 'node_modules|dist|build|target|.venv|__pycache__'` at the repo root. Include for each workspace package if it's a monorepo.
4. **Entry points and public API.** From `main`, `exports`, `bin`, `[[bin]]`, `[lib]`, framework conventions (Next routes, Django urls.py, etc.).
5. **Config surface.** tsconfig / `ruff.toml` / `clippy.toml` / ESLint / `.editorconfig` — anything that gates what's "correct."
6. **Test layout.** Where tests live, runner, coverage tool.
7. **Tool availability.** Check which cleanup tools are installed or available: `knip`, `ts-prune`, `madge`, `vulture`, `deadcode`, `cargo machete`, `cargo udeps`, `pydeps`, `depcheck`. Record commands that work; note any missing.
8. **Obvious landmines.** Generated code directories, vendored code, protobuf output, anything that must not be touched.

The brief is a compact, scannable markdown file — facts only, no prose commentary. The eight subagents each read it once instead of each re-deriving it.

## Phase 2 — Launch (one message, eight parallel spawns)

Send one message containing eight `Agent` calls. All: `subagent_type: general-purpose`, `model: opus`, `run_in_background: true`. Prefix every prompt with the same header:

```
Read .tmp/code-cleanup/brief.md before doing anything else.
It contains the codebase layout, build commands, test commands,
tool availability, and landmines. Do not re-derive any of it.

Your mandate: [agent-specific below]

Follow the Protocol (below).
```

Same header across all eight = cache hits on the prompt prefix. The mandate and any per-agent tail differ.

### Mandates

1. **Deduplicate.** Find repeated logic. Apply DRY only where it cuts real complexity — never abstraction for its own sake. Leave three-line repetition alone.
2. **Consolidate types.** Find type definitions duplicated across files or packages. Move shared shapes to one source of truth. Update every import.
3. **Dead code.** Run the tools the brief confirmed are installed. Remove unreferenced exports, files, and dependencies. Confirm each deletion with a grep across the full tree — tests, configs, dynamic imports included — before cutting.
4. **Circular dependencies.** Run `madge --circular` / `pydeps` / equivalent from the brief. Break every cycle by inverting a dependency or extracting the shared piece. Do not mask cycles with lazy imports.
5. **Weak types.** Find every `any`, `unknown`, `object`, `{}`, Python `Any`, Go `interface{}`, Rust `Box<dyn Any>`. For each one, read call sites, runtime values, and upstream package types. Replace with the real type. Typecheck must end green.
6. **Defensive programming.** Find every `try`/`catch` and equivalent. Keep it only when it handles real external input, a documented failure mode, or a boundary the caller cannot cross. Delete empty catches, silent fallbacks, and speculative guards. Errors propagate or handle specifically — never swallow.
7. **Legacy paths.** Find deprecated code, compat shims, fallback branches, `// TODO: remove after X` that outlived X, and feature flags long since defaulted. Delete them. Every path should be the single canonical path.
8. **AI slop.** Remove narration comments ("now we do X"), "replaced old Y with new Z" notes, commented-out code, obvious-from-code comments, and stub scaffolds. Keep comments that explain *why*, constraints, or non-obvious invariants. Rewrite kept comments for a new reader — no references to prior versions or the author's process.

### Protocol (every agent follows this)

1. **Read the brief.** `.tmp/code-cleanup/brief.md`. Do not re-derive what's already in it.
2. **Research your scope.** Enumerate every instance. No sampling.
3. **Assess.** Record severity per finding: high / medium / low confidence, with evidence.
4. **Fix high-confidence only.** Make the change. Run the brief's typecheck and test commands after each batch. Revert anything that breaks.
5. **Report.** Return: (a) full assessment, (b) changes made with file paths, (c) items skipped and why, (d) follow-ups for the main session.

## Rules

- **Scope is the mandate.** Agent 1 does not fix types. Agent 5 does not remove dead code. Cross-pollination creates conflicts.
- **Brief is canon.** Commands and tool names come from the brief. If an agent disagrees, flag it in the report rather than diverging silently.
- **Evidence before edits.** Findings without grep output, AST matches, or tool output are slop.
- **High confidence only touches code.** Medium and low confidence go in the report.
- **Prove every fix.** Typecheck and tests pass after each batch, or the batch reverts.
- **Shared tree.** Eight agents edit the same working copy. Expect conflicts. The main session reconciles after all return.

## Phase 3 — Reconcile

1. Present each agent's assessment inline.
2. Run full typecheck and test suite once more across the tree.
3. Resolve any overlapping edits; prefer the more conservative change.
4. Commit one concern per commit: `cleanup(dedup): …`, `cleanup(types): …`, etc.
5. List every medium- and low-confidence finding as a follow-up checklist for the user to triage.
6. Delete `.tmp/code-cleanup/`.
