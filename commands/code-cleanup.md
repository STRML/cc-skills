---
description: Deep codebase cleanup via eight parallel subagents that inherit this session's context. Each owns one concern — dedup, type consolidation, dead code, circular deps, weak types, defensive-programming cruft, legacy paths, AI slop. Uses cc-fork so spawns see the recon phase as live conversation, not a re-inlined brief.
---

# Code Cleanup

Recon once in this session, then fan out to eight forked subagents that inherit the conversation. Reconcile their reports.

**Dependency:** [`cc-fork`](https://github.com/STRML/cc-skills/tree/main/bin) on PATH. If it's missing, fall back to the Agent-tool recipe at the end.

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

Then run:

```bash
mkdir -p .tmp/code-cleanup/reports
cc-fork --output-dir .tmp/code-cleanup/reports \
  "MODE=<edit|dry-run>. Mandate: Deduplicate. Find repeated logic across the codebase you've seen. Apply DRY only where it cuts real complexity — never abstraction for its own sake; leave three-line repetition alone. Write your assessment, changes (or proposed changes in dry-run), items skipped with reasons, and main-session follow-ups to your report file. End with one line: WROTE_REPORT." \
  "MODE=<edit|dry-run>. Mandate: Consolidate types. Find type definitions duplicated across files or packages. Move shared shapes to one source of truth; update every import. Report format same as above." \
  "MODE=<edit|dry-run>. Mandate: Dead code. Run the tools we confirmed are installed. Remove unreferenced exports, files, and dependencies. Grep the full tree — tests, configs, dynamic imports included — before cutting. Report format same as above." \
  "MODE=<edit|dry-run>. Mandate: Circular dependencies. Run madge/pydeps/equivalent. Break every cycle by inverting a dependency or extracting the shared piece; do not mask with lazy imports. Report format same as above." \
  "MODE=<edit|dry-run>. Mandate: Weak types. Find every any/unknown/object/{}/Python Any/Go interface{}/Rust Box<dyn Any>. Read call sites and upstream types; replace with real types. Typecheck must end green. Report format same as above." \
  "MODE=<edit|dry-run>. Mandate: Defensive programming. Find every try/catch and equivalent. Keep only those handling real external input, documented failure modes, or caller-uncrossable boundaries. Delete empty catches, silent fallbacks, speculative guards. Report format same as above." \
  "MODE=<edit|dry-run>. Mandate: Legacy paths. Find deprecated code, compat shims, fallback branches, // TODO: remove after X that outlived X, feature flags long since defaulted. Delete. Every path should be the single canonical path. Report format same as above." \
  "MODE=<edit|dry-run>. Mandate: AI slop. Remove narration comments, 'replaced old Y with new Z' notes, commented-out code, obvious-from-code comments, stub scaffolds. Keep comments that explain why, constraints, or non-obvious invariants — rewrite them for a new reader, no references to prior versions. Report format same as above."
```

Substitute `edit` or `dry-run` for `<edit|dry-run>` in each task string before running.

cc-fork snapshots this session's JSONL, spawns 8 parallel `claude --resume` instances (each starts with the full recon phase as inherited context), collects outputs into the report dir, and cleans up its fork JSONLs on exit.

## Phase 3 — Reconcile

1. Read every file in `.tmp/code-cleanup/reports/fork-NN.out`. Full text — do not grep-skim.
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

## Fallback: no cc-fork

If cc-fork isn't installed, use the Agent tool with byte-identical prefix across 8 parallel spawns. The prefix must inline the full brief and protocol — forks don't see conversation history. Stagger spawn #1 until streaming confirms cache commit, then launch 2–8 in one message. This is the old recipe — inferior because each fork re-reads ambient context, but it works with zero install.
