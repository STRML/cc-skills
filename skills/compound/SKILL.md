---
name: compound
description: Use when a problem has been solved to document the solution for future reference. Invoke manually with /compound after confirming a fix works. Writes a structured solution to project memory so future sessions automatically have it.
argument-hint: "[optional: brief context about the fix]"
---

# /compound

Document a recently solved problem, writing it into the project memory system where future sessions automatically load it.

## Purpose

Captures solutions while context is fresh. First occurrence takes research; documented, the next takes minutes. Solutions go into memory (auto-loaded every session), not a docs folder nobody reads.

## Usage

```bash
/compound                    # Document the most recent fix
/compound [brief context]    # Provide additional context hint
```

This skill is manual-only. Do not auto-invoke on conversational phrases.

## Preconditions

- Problem has been solved and solution verified working
- Non-trivial problem (not a simple typo or obvious error)

If preconditions aren't met, say so and stop. If unsure whether the fix is verified, ask.

## Output

A single memory file in the project memory directory (path from system prompt context, e.g., `~/.claude/projects/<project-path>/memory/`):

- `memory/solution_<slug>.md` — structured solution with memory frontmatter
- `memory/MEMORY.md` — pointer line added to index

No other files are written.

## Execution

### Phase 0: Dedup Check

Before launching research, search existing `memory/solution_*.md` files for a solution covering the same root cause. Grep for the affected component name and key error message or symptom in both filenames and `description:` frontmatter fields.

- **If a match is found:** show it to the user and ask whether to update the existing entry or create a new one. If updating, skip Phase 1 and edit the existing file directly.
- **If no match:** proceed to Phase 1.

### Phase 1: Parallel Research

<critical_requirement>
Subagents return TEXT DATA only. They must NOT use Write, Edit, or create any files. Only the orchestrator (Phase 2) writes files.

ALL subagents must succeed before Phase 2. If any subagent fails or times out, abort and report which failed and why.
</critical_requirement>

Launch two subagents IN PARALLEL:

#### 1. Problem & Solution Extractor
- Extract from conversation history: problem type, component, symptoms, error messages
- Analyze investigation steps tried (including dead ends)
- Identify root cause with technical explanation
- Extract working solution with code examples
- Return: frontmatter fields + full solution content block

#### 2. Related Context & Prevention
- Search project memory and codebase for related documentation (use `mgrep` if available, fall back to Grep/Glob)
- Develop prevention strategies and test cases if applicable
- Suggest tags for discoverability
- Return: related links, prevention content, tags

### Phase 2: Assembly & Write

**WAIT for both Phase 1 subagents to complete successfully.**

#### Step 1: Generate slug

Derive from the problem title:
- Kebab-case, lowercase, max 50 characters
- Strip filler words (the, a, an, in, for, etc.)
- Example: "N+1 Query in Brief Generation" → `n-plus-1-query-brief-generation`

Check for collision with existing `memory/solution_<slug>.md`. If collision, append `-2` (or `-3`, etc.).

#### Step 2: Write the memory file

Create `memory/solution_<slug>.md`:

```markdown
---
name: solution-<slug>
description: <one-line description — specific enough for future sessions to judge relevance>
type: project
---

## Problem

[Exact error messages, observable behavior]

## Root Cause

[Technical explanation — be specific, this is the most valuable part]

## Solution

[Concise fix with key code snippets]

## Prevention

[How to avoid this in the future]

## References

[Related files, PRs, commits, or other memory entries]
```

The `description` field determines whether future sessions find this. Be specific: "N+1 query in brief generation causing 30s page loads" not "performance issue fix".

#### Step 3: Update MEMORY.md

Check MEMORY.md line count first. If at or above 190 lines, warn the user that memory is near capacity and suggest pruning stale entries before adding more.

Create the memory directory if it doesn't exist (`mkdir -p`). Create MEMORY.md if absent.

Add a pointer line following the existing format. Keep MEMORY.md as an index — no content, just links with brief descriptions.

## Common Mistakes

| Wrong | Correct |
|-------|---------|
| Subagents write files | Subagents return text; orchestrator writes |
| Phase 2 runs before Phase 1 completes | Wait for both subagents to succeed |
| Vague description: "fixed a bug" | Specific: "CAN bus timing overflow in GCU shift logic at >8000 RPM" |
| Writing without dedup check | Always check existing solutions first |
| Adding pointer to full MEMORY.md | Check line count, warn at/above 190 |

## Success Output

```
Done — solution documented.

Memory: memory/solution_<slug>.md
MEMORY.md: pointer added ([N] lines, [capacity status])
```
