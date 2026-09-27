---
name: compound
description: Use when a problem has been solved to document the solution for future reference. Invoke manually with /compound after confirming a fix works. Saves a structured solution note to shared Mnemopi memory (through the cross-agent-context skill) so future sessions in Claude Code, OMP, or Codex can recall it.
argument-hint: "[optional: brief context about the fix]"
---

# /compound

Document a recently solved problem as a durable note in shared Mnemopi memory, where future sessions recall it.

## Purpose

Captures solutions while context is fresh. First occurrence takes research; documented, the next takes minutes. Solutions go into shared memory, which every harness recalls, not a docs folder nobody reads.

## Usage

```bash
/compound                    # Document the most recent fix
/compound [brief context]    # Provide additional context hint
```

This skill is manual-only. Do not auto-invoke on conversational phrases.

## Preconditions

- Problem has been solved and solution verified working
- Non-trivial problem (not a simple typo or obvious error)

If preconditions aren't met, say so and stop. If you cannot tell whether the fix was verified, look in the conversation for a passing test or command output; if there is none, say the fix is unverified and stop.

## Output

One Mnemopi note with `kind: "solution"` in the project's `retainBank`. No files are written. Legacy Markdown memory (`memory/MEMORY.md`, `memory/*.md`) is a migration source and is not written.

Load the `cross-agent-context` skill first if it is not loaded. Its `references/memory.md` has the tool arguments and the `shared-memory` CLI fallback.

## Execution

Do this in the main loop. The conversation is the source, and a fresh subagent cannot see it.

### Step 1: Resolve the bank

Run `shared-memory context --cwd <absolute checkout path>`. In a git worktree, also run it for the main checkout and use the main checkout's `retainBank`, so the note is repository-wide.

### Step 2: Dedup check

Call `mnemopi_recall` on each `recallBanks` entry with the affected component name plus the key error message or symptom. Read promising hits in full with `mnemopi_get`.

- **A note covers the same root cause:** replace it. Save the corrected note (Step 4) with the old ID in its metadata, verify it, then call `mnemopi_invalidate` with `replacement_id`. Say that you replaced an existing note.
- **No match:** continue.

### Step 3: Extract the solution

From the conversation, collect:

- Problem: exact error messages, observable behavior, component
- Investigation: steps tried, including dead ends
- Root cause, with a technical explanation
- Working solution, with key code snippets
- Prevention: how to avoid it, and a test that would catch it
- References: related files, PRs, commits, issues. Search the codebase with Grep/Glob for related code if the conversation does not name it.

### Step 4: Save the note

Call `mnemopi_remember` with `bank` set to the `retainBank`, `scope: "bank"`, `source: "claude-code"`, and content in this shape:

```markdown
Solution: <one-line description, specific enough for future recall to judge relevance>

## Problem
[Exact error messages, observable behavior]

## Root Cause
[Technical explanation. Be specific; this is the most valuable part]

## Solution
[Concise fix with key code snippets]

## Prevention
[How to avoid this in the future]

## References
[Related files, PRs, commits, issues]
```

Metadata: `{ "cwd": "<checkout>", "kind": "solution", "task": "<slug>", "tags": [...], "recorded_at": "<ISO timestamp>" }`. The slug is kebab-case, lowercase, at most 50 characters, filler words stripped (e.g. "N+1 Query in Brief Generation" → `n-plus-1-query-brief-generation`).

The first line decides whether future recall finds this. Be specific: "N+1 query in brief generation causing 30s page loads", not "performance issue fix".

### Step 5: Verify

Check the returned `memory_id`, then `mnemopi_get` it. If the result is `mutation_committed_journal_incomplete`, do not retry; follow the recovery steps in `cross-agent-context/references/memory.md`. If both the MCP tools and the CLI fail, say persistence failed.

## Common Mistakes

| Wrong | Correct |
|-------|---------|
| Writing to `memory/MEMORY.md` or `memory/solution_*.md` | Save to Mnemopi with `mnemopi_remember` |
| Guessing the bank | Use `retainBank` from `shared-memory context` |
| Vague first line: "fixed a bug" | Specific: "CAN bus timing overflow in GCU shift logic at >8000 RPM" |
| Saving without a dedup recall | Recall first; replace and invalidate a matching note |
| Claiming saved without checking | Verify the `memory_id` with `mnemopi_get` |

## Success Output

```
Done — solution documented.

Memory: <bank> / <memory_id> (solution: <slug>)
```
