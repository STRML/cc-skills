# cc-skills

A small, opinionated collection of [Claude Code](https://claude.com/claude-code) slash commands, skills, and CLI tools I actually use.

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

## At a glance

| Name | Type | What it does |
|---|---|---|
| [`/code-cleanup`](commands/code-cleanup.md) | command | Maps the repo once, then forks eight cache-sharing subagents, one per concern (dead code, weak types, AI slop, ...) |
| [`/check-pr-reviews`](commands/check-pr-reviews.md) | command | Fetch and address review comments on the current branch's PR |
| [`recall`](skills/recall/SKILL.md) | skill | Search past Claude Code sessions |
| [`compound`](skills/compound/SKILL.md) | skill | Save a hard-won fix's root cause into project memory |
| [`session-learnings`](skills/session-learnings/SKILL.md) | skill | Update `CLAUDE.md` with the session's lessons |
| [`scan-diff`](skills/scan-diff/SKILL.md) | skill | Cheap Haiku bug scan of the current diff |
| [`cr-check`](skills/cr-check/SKILL.md) | skill | Fetch or wait for a CodeRabbit review and return only the findings |
| [`coderabbit-new`](skills/coderabbit-new/SKILL.md) | skill | Show only CodeRabbit comments added since a commit |
| [`commit-and-verify`](skills/commit-and-verify/SKILL.md) | skill | Check hooks, diff and secrets, then commit |
| [`visual-css-refinement`](skills/visual-css-refinement/SKILL.md) | skill | Screenshot-driven loop for CSS and UI changes |
| [`session-close-sweep`](skills/session-close-sweep/SKILL.md) | skill | End-of-session audit of issues, git state and docs |
| [`progress-dashboard`](skills/progress-dashboard/SKILL.md) | skill | Live local HTML dashboard for long agent runs |
| [`migrate-to`](skills/migrate-to/SKILL.md) | skill | Fork the running session onto another machine over ssh |
| [`fanout`](skills/fanout/SKILL.md) | skill | Deep bug review: map the repo once, fork N method lenses with a staggered launch, triage in one place |

## Commands

### [`/code-cleanup`](commands/code-cleanup.md)

Deep codebase cleanup that maps the repo once, then forks eight subagents off that map. The order is the point. Recon (tree, build, typecheck and test commands, conventions) happens first, in your own session, so it becomes conversation history. Then eight `fork` subagents launch in one message. Each inherits the full conversation and reuses the same cached prompt prefix, so none of them re-reads the repo or needs a brief pasted in. The eighth fork costs far less than the first.

```
your session: recon ─▶ map of the repo, now in context (cached prefix)
                  ├─▶ fork 1  dedup          ┐
                  ├─▶ fork 2  shared types   │  all eight inherit the map,
                  ├─▶  ...                   │  run in parallel, and write
                  └─▶ fork 8  AI slop        ┘  .tmp/code-cleanup/reports/
your session: triage the eight reports ─▶ apply edits, one concern per commit
```

Each fork owns one concern:

1. Deduplicate repeated logic (DRY where it cuts complexity)
2. Consolidate shared type definitions
3. Remove dead code (`knip`, `vulture`, `cargo machete`, etc.)
4. Break circular dependencies (`madge`, `pydeps`)
5. Replace weak types (`any`, `unknown`, `interface{}`) with real ones
6. Strip defensive programming that hides errors instead of handling them
7. Delete deprecated code, compat shims, and orphaned feature flags
8. Remove AI slop — narration comments, stubs, commented-out code

The forks never edit. Eight writers on one working tree would walk over each other, and eight worktrees are impractical, so each fork writes a report of proposed changes with evidence and a confidence rating. Your session then triages all eight: it merges overlapping proposals, asks before anything that could break dynamic wiring or a public API, and applies the rest one concern at a time, with typecheck and tests (and a commit) after each. Dispatch uses the built-in `subagent_type: "fork"` (Claude Code ≥ 2.1.229); older versions fall back to the Agent-tool + cached-prefix recipe.

### [`/check-pr-reviews`](commands/check-pr-reviews.md)

Fetch and address comments on the current branch's PR. Handles CodeRabbit, Claude-bot, and human reviewers differently. Verifies findings against current code before fixing.

## Skills

### [`recall`](skills/recall/SKILL.md)

Search past Claude Code session history via [search-sessions](https://github.com/sinzin91/search-sessions). Supports metadata queries (instant), full-content deep search, date filters, and project filters. Use when you need to find what was done in a previous session.

### [`compound`](skills/compound/SKILL.md)

After a hard-won fix, capture the root cause and solution into project memory where future sessions auto-load it. Runs two parallel research subagents, then writes a structured `memory/solution_<slug>.md` and updates the `MEMORY.md` index.

### [`session-learnings`](skills/session-learnings/SKILL.md)

End-of-session skill that updates the project's `CLAUDE.md` with lessons learned — non-obvious commands, corrections, gotchas. Fires on `/clear`, `PreCompact`, or explicit invocation. Filters out generic advice and obvious conventions.

### [`scan-diff`](skills/scan-diff/SKILL.md)

Quick bug-scan pass on the current git diff via a focused Haiku subagent. Targets logic errors, null access, auth bypasses, race conditions. Skips style and formatting. Not a replacement for full review — a cheap first filter.

### [`cr-check`](skills/cr-check/SKILL.md)

Fetch, wait for, or re-trigger a CodeRabbit review on a PR and get back only the findings, typically under 5 KB. `scripts/cr-check.sh` strips the analysis chains, prompt blocks, autofix and run-info sections, and prints the bot's verdict on HEAD next to GitHub's aggregate `reviewDecision`. It detects paused, rate-limited and fair-usage-capped reviews, and can wait those out and re-trigger. A capped CodeRabbit still posts a passing status check, so it warns when that check is all you have. Needs `gh` and `jq`.

### [`coderabbit-new`](skills/coderabbit-new/SKILL.md)

Filter a PR's CodeRabbit comments to only those added since a given commit. Cuts through re-shown stale comments so you only triage what's actually new.

### [`commit-and-verify`](skills/commit-and-verify/SKILL.md)

Pre-commit verification workflow. Checks for pre-commit hooks first (skips redundant runs), reviews `git status` and `git diff`, catches debug code and secrets, stages selectively, and writes a structured Conventional-Commits-style message. Pushes only on explicit request.

### [`visual-css-refinement`](skills/visual-css-refinement/SKILL.md)

Screenshot-driven loop for CSS/UI work. Forces a "before" screenshot baseline, then iterates: change → screenshot → compare → confirm. Prevents blind edits and the "I think it should look better now" failure mode. Includes responsive-breakpoint verification.

### [`session-close-sweep`](skills/session-close-sweep/SKILL.md)

End-of-session audit for a repo with a GitHub tracker. It lists every open issue, checks each against origin/main and production, closes the stale ones with an evidence comment, and batches the ones that need an owner decision into a single question. It also checks git state (dirty tree, unpushed commits, leftover worktrees and stashes), flags docs the session contradicted, and offers to keep the scripts and gotchas the session produced. Ends with a closed/remains report. Needs the `gh` CLI.

### [`progress-dashboard`](skills/progress-dashboard/SKILL.md)

A live HTML dashboard for long agent runs: an epic, a PR landing queue, hours of autonomous work. `scripts/dash.py` is the only writer (locked, atomic, safe for a main session and subagents at once); `dash.py serve` puts the page on `127.0.0.1` and it refreshes every 10 seconds. It shows task progress with a dependency-driven Flow panel, open questions (each with the default the agent proceeds on, newest first, answered ones folded away), blockers, deliverables, two metric tiles and an activity log. Answers typed on the page come back to the agent on its next `dash.py` command. State lives in `<repo>/.dashboard/` and stays out of git. Standard library Python 3, no dependencies.

### [`migrate-to`](skills/migrate-to/SKILL.md)

`/migrate-to <host>` forks the running Claude Code session onto another machine over ssh and keeps going there. `cmux session move` refuses a session that is still running, so the script copies the transcript under a new id (cut just before the `/migrate-to` prompt) and moves the copy - your local session stays live. The fork gets the cwd repo's HEAD plus modified and untracked files, the other repos the session touched, and gitignored loose files like `.env`. It resumes as a window in one shared `migrate` tmux session on the host with Remote Control on, and a cmux pane opens beside yours without taking focus. `list` and `clean` show and tear down what's running there. Short host names map to ssh destinations in `~/.config/migrate-to/hosts`. Needs cmux and jq locally, tmux on the host, git and rsync on both, Claude Code signed in to the same account on both, and the same home path on both.

### [`fanout`](skills/fanout/SKILL.md)

A deep bug review that maps the repo once, then forks N subagents that each look at the code by a different method: trace data flow, break the documented invariants, diff code that should behave the same, walk the boundary cases. The forks inherit the map and only write reports; your session deduplicates, verifies and ranks the findings.

Measured on react-grid-layout with Sonnet 5.5 against a corpus of reverted bug fixes ([`bench/README.md`](skills/fanout/bench/README.md)):

| | Real issues per run | Cost per run |
|---|---|---|
| single agent | 11 | $0.79 |
| 4 fresh agents, same lenses | 23 | $3.08 |
| **4 forks, staggered launch** | **30** | **$1.82** |

Two things carry most of that. Launch one fork first and the rest in the next message: launched together, every fork rebuilt the shared prefix (each wrote ~154K cache tokens), and staggering cut the forks' cache writes 6.4×. And split lenses by method rather than topic, which found more issues no other configuration did. Starting agents fresh did not buy more coverage; a second forked batch is the cheaper way to get it.

Only the review preset ships. Cleanup, simplify, security and test-audit presets were not measured, so they are left out rather than built on faith. `/code-cleanup` keeps its own lenses but now uses the staggered launch. The `bench/` scripts rerun the whole measurement on another repo; `scripts/usage.py` shows any session's per-subagent cache reads and writes.

## Contributing

PRs welcome. One skill or command per PR, please. Each addition should include a short rationale in the description — what problem it solves, what it doesn't try to do.

## License

MIT
