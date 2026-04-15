# cc-skills

A small, opinionated collection of [Claude Code](https://claude.com/claude-code) slash commands, skills, and CLI tools I actually use.

Everything here is MIT-licensed. Grab what's useful; ignore the rest.

## Install

```bash
git clone git@github.com:STRML/cc-skills.git
```

Then symlink (or copy) what you want into your Claude Code config:

```bash
# CLI tools → somewhere on PATH
ln -s "$(pwd)/cc-skills/bin/cc-fork" ~/.local/bin/cc-fork

# Slash commands → ~/.claude/commands/
ln -s "$(pwd)/cc-skills/commands/code-cleanup.md" ~/.claude/commands/code-cleanup.md

# Skills → ~/.claude/skills/
ln -s "$(pwd)/cc-skills/skills/scan-diff" ~/.claude/skills/scan-diff
```

Slash commands become available immediately. Skills require a session restart to appear in the Skill tool list.

## Layout

```
bin/        Standalone CLI tools
commands/   Slash commands — invoke with /<name>
skills/     Skills — invoke via the Skill tool
```

## CLI tools

### `cc-fork`

Spawn N parallel Claude Code subagents that inherit the current session's context — the thing built-in subagents don't do.

Built-in `Agent`/`Task` spawns start with a blank conversation: they can't see your exploration, your clarifications with the user, or anything else that's happened. They re-read the codebase from scratch every time. `cc-fork` sidesteps this by snapshotting the current session's JSONL, copying it to N new UUIDs, and launching `claude --resume` on each. Every fork starts as a branch of the live conversation.

```bash
cc-fork "task 1" "task 2" "task 3"                       # stdout output
cc-fork --model haiku "quick task A" "quick task B"      # specify model
cc-fork --output-dir .tmp/reports "task1" "task2"        # write to files
cc-fork --parent <uuid> "task"                           # specific parent session
cc-fork --keep "task"                                    # don't cleanup forked JSONLs
```

Defaults:
- Parent session = largest JSONL in the current working dir's project dir
- Stagger = 1s between launches (required — simultaneous launches race on Claude Code's session-index)
- Cleanup = ON (deletes forked JSONLs + metadata sidecars on exit)

Requires Python 3 and the `claude` CLI on PATH. Zero pip deps.

**When to use it:** fan-out tasks where re-explaining context is wasteful — codebase audits, multi-angle reviews, parallel refactors. Each fork pays full parent-context tokens, but prompt-cached across spawns after the first.

**When not to use it:** single-shot tasks (just run them), or tasks that need fresh context on purpose (use `Agent` instead).

## Commands

### `/code-cleanup`

Deep codebase cleanup via eight parallel subagents that inherit this session's context (requires `cc-fork` on PATH). Recon happens in the current conversation; the eight forks see it as live history, so there's no need to inline a brief. Each fork owns one concern:

1. Deduplicate repeated logic (DRY where it cuts complexity)
2. Consolidate shared type definitions
3. Remove dead code (`knip`, `vulture`, `cargo machete`, etc.)
4. Break circular dependencies (`madge`, `pydeps`)
5. Replace weak types (`any`, `unknown`, `interface{}`) with real ones
6. Strip defensive programming that hides errors instead of handling them
7. Delete deprecated code, compat shims, and orphaned feature flags
8. Remove AI slop — narration comments, stubs, commented-out code

The command offers an **edit mode** (make high-confidence fixes in place) and a **dry-run mode** (evidence-backed reports only, reconcile with human triage). Dry-run is the safer default for fragile or first-time codebases. Falls back to the Agent-tool + cached-prefix recipe if `cc-fork` isn't installed.

### `/check-pr-reviews`

Fetch and address comments on the current branch's PR. Handles CodeRabbit, Claude-bot, and human reviewers differently. Verifies findings against current code before fixing.

### `/init`

Bootstrap a project for Claude Code — analyze the repo, write `CLAUDE.md` with commands and conventions, and optionally scaffold `.devcontainer/devcontainer.json` with a language-detected base image.

## Skills

### `recall`

Search past Claude Code session history via [search-sessions](https://github.com/sinzin91/search-sessions). Supports metadata queries (instant), full-content deep search, date filters, and project filters. Use when you need to find what was done in a previous session.

### `compound`

After a hard-won fix, capture the root cause and solution into project memory where future sessions auto-load it. Runs two parallel research subagents, then writes a structured `memory/solution_<slug>.md` and updates the `MEMORY.md` index.

### `session-learnings`

End-of-session skill that updates the project's `CLAUDE.md` with lessons learned — non-obvious commands, corrections, gotchas. Fires on `/clear`, `PreCompact`, or explicit invocation. Filters out generic advice and obvious conventions.

### `scan-diff`

Quick bug-scan pass on the current git diff via a focused Haiku subagent. Targets logic errors, null access, auth bypasses, race conditions. Skips style and formatting. Not a replacement for full review — a cheap first filter.

### `coderabbit-new`

Filter a PR's CodeRabbit comments to only those added since a given commit. Cuts through re-shown stale comments so you only triage what's actually new.

### `commit-and-verify`

Pre-commit verification workflow. Checks for pre-commit hooks first (skips redundant runs), reviews `git status` and `git diff`, catches debug code and secrets, stages selectively, and writes a structured Conventional-Commits-style message. Pushes only on explicit request.

### `visual-css-refinement`

Screenshot-driven loop for CSS/UI work. Forces a "before" screenshot baseline, then iterates: change → screenshot → compare → confirm. Prevents blind edits and the "I think it should look better now" failure mode. Includes responsive-breakpoint verification.

## Contributing

PRs welcome. One skill or command per PR, please. Each addition should include a short rationale in the description — what problem it solves, what it doesn't try to do.

## License

MIT
