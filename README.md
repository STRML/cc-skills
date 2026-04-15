# cc-skills

A small, opinionated collection of [Claude Code](https://claude.com/claude-code) slash commands and skills I actually use.

Everything here is MIT-licensed. Grab what's useful; ignore the rest.

## Install

```bash
git clone git@github.com:STRML/cc-skills.git
```

Then symlink (or copy) what you want into your Claude Code config:

```bash
# Slash commands → ~/.claude/commands/
ln -s "$(pwd)/cc-skills/commands/code-cleanup.md" ~/.claude/commands/code-cleanup.md

# Skills → ~/.claude/skills/
ln -s "$(pwd)/cc-skills/skills/scan-diff" ~/.claude/skills/scan-diff
```

Slash commands become available immediately. Skills require a session restart to appear in the Skill tool list.

## Layout

```
commands/   Slash commands — invoke with /<name>
skills/     Skills — invoke via the Skill tool
```

## Commands

### `/code-cleanup`

Deep codebase cleanup via eight parallel subagents. A single recon pass up front builds a shared context brief (languages, build commands, available tooling, landmines). The brief is inlined verbatim as the prefix of each subagent's prompt — identical across all eight — so spawns 2–8 hit Anthropic's prompt cache for the shared portion.

Each agent owns one concern:

1. Deduplicate repeated logic (DRY where it cuts complexity)
2. Consolidate shared type definitions
3. Remove dead code (`knip`, `vulture`, `cargo machete`, etc.)
4. Break circular dependencies (`madge`, `pydeps`)
5. Replace weak types (`any`, `unknown`, `interface{}`) with real ones
6. Strip defensive programming that hides errors instead of handling them
7. Delete deprecated code, compat shims, and orphaned feature flags
8. Remove AI slop — narration comments, stubs, commented-out code

The command offers an **edit mode** (make high-confidence fixes in place) and a **dry-run mode** (evidence-backed reports only, reconcile with human triage). Dry-run is the safer default for fragile or first-time codebases.

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
