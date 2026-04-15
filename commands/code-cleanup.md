---
description: Deep codebase cleanup. A single recon pass builds a shared context brief, then eight subagents each own one concern — dedup, type consolidation, dead code, circular deps, weak types, defensive-programming cruft, legacy paths, AI slop. Shared long prefix means spawns 2-8 hit the prompt cache.
---

# Code Cleanup

One recon pass, then eight subagents. Shared context first — saves tokens, keeps findings aligned.

## How subagents actually work (important)

Subagents do NOT inherit parent context. A `general-purpose` spawn starts fresh: it sees only the harness's system prompt for that agent type plus the `prompt` string you pass. No parent conversation history, no tool results, no loaded files. If the spawn needs to know something, you must include it in the prompt.

This affects the phase 2 strategy:
- **Do not** tell spawns to "read the brief at `.tmp/code-cleanup/brief.md`" — that wastes a tool call and a ~20KB tool result per spawn, and the cached prefix is too short to help
- **Do** inline the full brief contents (plus protocol) at the START of each prompt as a long identical prefix, with the per-agent mandate at the END
- Anthropic's prompt cache has a 1024-token minimum and a 5-minute TTL. A 15KB shared prefix easily caches; spawns 2–8 hit it

## Phase 1 — Recon (main session, do this once)

Build the shared brief. Do not skip items; missing context forces spawns to re-explore. Write the brief to `.tmp/code-cleanup/brief.md` (also used as the canonical source for inlining into each spawn's prompt).

Gather:

1. **Languages and package managers.** Read every root manifest (`package.json`, `pyproject.toml`, `Cargo.toml`, `go.mod`, etc.). Note workspace layout.
2. **Build, typecheck, test, lint commands.** From the manifest and any `Makefile` / `justfile` / `turbo.json` / `nx.json`.
3. **Tree.** `tree -L 3 -I 'node_modules|dist|build|target|.venv|__pycache__'` at the repo root. Include for each workspace package if it's a monorepo.
4. **Entry points and public API.** From `main`, `exports`, `bin`, `[[bin]]`, `[lib]`, framework conventions (Next routes, Django urls.py, etc.).
5. **Config surface.** tsconfig / `ruff.toml` / `clippy.toml` / ESLint / `.editorconfig` — anything that gates what's "correct."
6. **Test layout.** Where tests live, runner, coverage tool.
7. **Tool availability.** Check which cleanup tools are installed or available: `knip`, `ts-prune`, `madge`, `vulture`, `deadcode`, `cargo machete`, `cargo udeps`, `pydeps`, `depcheck`. Record commands that work; note any missing.
8. **Obvious landmines.** Generated code directories, vendored code, protobuf output, anything that must not be touched.

The brief is a compact, scannable markdown file — facts only, no prose commentary. It gets inlined into each spawn's prompt verbatim.

## Phase 2 — Launch (staggered: one warm-up spawn, then seven parallel)

Each spawn's prompt has this shape:

```
<SHARED PREFIX — identical across all 8 spawns, ideally 10–20KB>

## Codebase brief
<full contents of .tmp/code-cleanup/brief.md, inlined>

## Protocol
<shared protocol: no-edit / edit mode, evidence requirements, report path,
scope rules, severity rubric, verification commands, landmines>

<PER-AGENT TAIL — varies>

## Your mandate
<one of the 8 mandates below, with specifics>

## Your report file
Write findings to .tmp/code-cleanup/reports/<NN-agent-name>.md
```

The shared prefix MUST be byte-identical across all 8 spawns. Any divergence (even a single differing token) breaks the cache from that point onward.

**Launch sequence:**

1. Launch spawn #1 (any mandate). Set `subagent_type: general-purpose`, `model: opus`, `run_in_background: true`.
2. Wait ~10–15 seconds. This lets the cache commit server-side so subsequent spawns hit it instead of racing to write it.
3. Launch spawns #2–#8 in a single message with seven parallel `Agent` tool calls, all same `subagent_type`/`model`/`run_in_background`.

Why staggered: firing all 8 simultaneously creates a race — the first request primes the cache, but requests 2–8 may arrive before the cache commit. The ~10-second gap guarantees cache hits on the remaining 7, for roughly 7× the shared prefix in token savings.

### Mandates

1. **Deduplicate.** Find repeated logic. Apply DRY only where it cuts real complexity — never abstraction for its own sake. Leave three-line repetition alone.
2. **Consolidate types.** Find type definitions duplicated across files or packages. Move shared shapes to one source of truth. Update every import.
3. **Dead code.** Run the tools the brief confirmed are installed. Remove unreferenced exports, files, and dependencies. Confirm each deletion with a grep across the full tree — tests, configs, dynamic imports included — before cutting.
4. **Circular dependencies.** Run `madge --circular` / `pydeps` / equivalent from the brief. Break every cycle by inverting a dependency or extracting the shared piece. Do not mask cycles with lazy imports.
5. **Weak types.** Find every `any`, `unknown`, `object`, `{}`, Python `Any`, Go `interface{}`, Rust `Box<dyn Any>`. For each one, read call sites, runtime values, and upstream package types. Replace with the real type. Typecheck must end green.
6. **Defensive programming.** Find every `try`/`catch` and equivalent. Keep it only when it handles real external input, a documented failure mode, or a boundary the caller cannot cross. Delete empty catches, silent fallbacks, and speculative guards. Errors propagate or handle specifically — never swallow.
7. **Legacy paths.** Find deprecated code, compat shims, fallback branches, `// TODO: remove after X` that outlived X, and feature flags long since defaulted. Delete them. Every path should be the single canonical path.
8. **AI slop.** Remove narration comments ("now we do X"), "replaced old Y with new Z" notes, commented-out code, obvious-from-code comments, and stub scaffolds. Keep comments that explain *why*, constraints, or non-obvious invariants. Rewrite kept comments for a new reader — no references to prior versions or the author's process.

### Ask the user: edit or dry-run?

Before launching, offer two modes:

- **Edit mode** — spawns make high-confidence changes, run typecheck + tests after each batch, revert on failure. Risk: with 8 spawns on a shared working copy, overlapping edits create conflicts; a single over-aggressive delete can break production wiring (especially in WordPress plugins where hooks fire dynamically).
- **Dry-run mode** — spawns produce evidence-backed reports only. No edits. The main session reconciles findings and triages them with the user. Safer for high-risk codebases, fragile test harnesses, or first-time use on a new codebase.

Default to asking unless the user specified. If unsure which, recommend dry-run.

### Protocol (included in each spawn's prompt)

1. **Research your scope.** Enumerate every instance. No sampling. The brief's "In-Scope" and "Out-of-Scope / Landmines" sections are authoritative for where to look.
2. **Assess.** Record severity per finding: high / medium / low confidence, with evidence (file + line, snippet, proposed change, risk).
3. **In edit mode:** fix high-confidence only. Run the brief's typecheck and test commands after each batch. Revert anything that breaks.
4. **In dry-run mode:** no edits. Write a structured report only.
5. **Report.** Write to `.tmp/code-cleanup/reports/<NN-agent-name>.md`. Return (a) one-paragraph summary, (b) path to the report. The main session reads the full report during reconcile.

## Rules

- **Scope is the mandate.** Spawn 1 does not fix types. Spawn 5 does not remove dead code. Cross-pollination creates conflicts.
- **Brief is canon.** Commands, tool names, landmines, and scope come from the inlined brief. If a spawn disagrees, it flags in the report rather than diverging silently.
- **Evidence before edits.** Findings without grep output, AST matches, or tool output are slop.
- **High confidence only touches code** (edit mode).
- **Prove every fix.** Typecheck and tests pass after each batch, or the batch reverts (edit mode).
- **Shared tree.** In edit mode, 8 spawns edit one working copy. Expect conflicts. In dry-run, there is no conflict — reports are independent.
- **Edit the source, not the installed copy.** The brief specifies which paths are source of truth vs. deploy artifacts (relevant for WordPress monorepos, Cargo workspaces with vendored crates, etc.).

## Phase 3 — Reconcile

1. Read each report in `.tmp/code-cleanup/reports/`.
2. **Edit mode:** run full typecheck and test suite once more across the tree. Resolve any overlapping edits; prefer the more conservative change. Commit one concern per commit: `cleanup(dedup): …`, `cleanup(types): …`, etc.
3. **Dry-run mode:** present findings to the user, grouped by mandate and severity. User triages which to apply. Then either apply them here in the main session (for small batches) or spawn targeted follow-up agents (for large batches).
4. List every medium- and low-confidence finding as a follow-up checklist.
5. Delete `.tmp/code-cleanup/` once the user confirms they're done with the reports.

## Token-efficiency notes

- The shared prefix (brief + protocol) is typically 10–20KB. Fire spawn #1 first, wait ~10s, fire #2–#8 together to guarantee cache hits on the prefix for 7 of 8 spawns.
- Do NOT ask spawns to read the brief from disk. The cache win comes from having identical prompt text, not from reading the same file.
- Each spawn's conversation is independent; tool-result caching does not transfer across spawns. Only the prompt prefix caches.
- Per-agent tails should be at the END of the prompt, after all shared content. Anything before the divergence point caches; anything after does not.
