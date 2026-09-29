---
name: progress-dashboard
description: Live HTML progress dashboard for a long epic (many issues or PRs, hours of work). Set it up before starting, update it after every step, and park decisions for Sam in its questions list with the default you proceed on. Use for "dashboard", "track progress", long autonomous runs, epics, landing queues.
---

# Progress dashboard

One HTML page Sam double-clicks and leaves open. It refreshes itself every 10 seconds and shows:

- task progress (every task with its status, the one in progress highlighted)
- questions waiting on Sam, each with the default you are using until he answers
- blockers
- latest deliverables (PRs, commits, files) with links
- up to two task-specific metric tiles (tests passing, PRs landed, ...) and an activity log
- a Flow panel: tasks grouped into steps from their dependencies, so Sam sees what runs in
  parallel and what waits in series
- the repo name in the page title and header; every `#123` and `owner/repo#123` links to GitHub

Style is fixed and already chosen by Sam: dark, dense, one violet accent, Linear-like cards
(see `style.md`). Do not ask about style again, and do not restyle per task. Pick the content
(tasks, metrics, wording) for the task at hand.

## Files

```
~/.claude/skills/progress-dashboard/
├── SKILL.md
├── style.md              Sam's saved style choice
├── assets/index.html     the renderer (never hand-edit a copy; fix it here)
└── scripts/dash.py       the only writer of dashboard state
<repo>/.dashboard/<name>/  one dashboard: index.html, state.json, state.js
```

The dashboard lives in `<git toplevel>/.dashboard/main/` by default (`--name` for a second one,
`--dir` or `$DASH_DIR` to put it elsewhere). `init` adds `/.dashboard/` to `.git/info/exclude`,
so it never shows in `git status` and never gets committed.

## Flow

1. **Before the first step:** `init` with every task you plan. Titles are short verbs a person
   reads at a glance; put the specifics in `:: detail`. Hand the `dashboard-builder` subagent the
   plan if you want it built in the background; doing it inline is one command.
2. **Serve it and open it once:** start `dash.py serve` as a long-lived background service
   (omp: a named bash service with `ready: {port}`; Claude Code: `run_in_background`), then
   `open http://127.0.0.1:<port>/`. Served, the page gets an answer box and a "Use default"
   button on every open question. Give Sam the URL in chat too. The port is stable per dashboard
   (printed by `serve`); pass `--port` to pick one.
3. **Every step:** `start N` when you begin, `done N` when it's verified, `ship` for anything he
   can click, `log` for one line of what happened. Update right after the event, never in batches
   at the end; the page shows "Updated … ago" and turns amber when it goes stale.
4. **Decision needed from Sam:** `ask "Question?" --default "What I'll do"`, then keep working on
   the default. The dashboard is where questions wait; don't stop the run for them.
   **Answers he types on the page are printed by your next `dash.py` command** as
   `ANSWER FROM SAM qN: ... -> ...` on stderr (so `>/dev/null` doesn't hide it). Act on it right
   away and record it where the project records rulings. `dash.py inbox` checks without updating.
   If he answers in chat instead, `answer qN "..."`.
5. **Stuck:** `block "what and why"`; `unblock bN` when it clears. A blocker flips the status
   pill to At risk automatically.
6. **End:** mark the last task done and `status finished`.

## Commands

```bash
D=~/.claude/skills/progress-dashboard/scripts/dash.py
$D init "Land the epic 372 PR queue onto the integration branch" --short "Epic 372" \
   --context "GCU · epic/372-integration · battery + CI per PR" \
   --task "Land #462 :: walk completeness" --task "Land #530 :: scratch pruner"
$D dep 5 3,4          # task 5 waits for 3 and 4 (drives the Flow panel); task add --after 3,4
$D start 1            # one task in progress at a time (--keep to allow two)
$D done 1 --detail "landed 609d4c58"
$D task add "Re-shoot frames 01/05/08" --detail "after fidelity PRs land"
$D task set 4 blocked --detail "waiting on guest"
$D ask "Land #466 without a fifth round?" --default "Hold #466; land the rest"
$D answer q1 "yes, land it"
$D withdraw q1                                  # a question that no longer applies
$D block "Guest VM busy with aim-configs"      # -> b1
$D unblock b1
$D ship "PR #467 landed" --link https://github.com/owner/repo/pull/467
$D metric "PRs landed" 3 --total 12            # tile with a bar
$D metric "CI" green --note "on 609d4c58"      # tile with a note
$D log "battery green on 0f11aab6"
$D status at_risk | on_track | blocked | finished
$D set --context "..."                         # also --title, --short, --repo, --github owner/repo
$D show                                        # text summary + path
$D inbox                                       # answers Sam gave on the page
$D serve [--port 8772]                         # page with answer boxes on 127.0.0.1
```

Statuses: `todo doing done blocked skipped`. Tasks are addressed by their 1-based number.
Every timestamp comes from the real clock at the moment of the command; never write times by hand.

## Rules

- `dash.py` is the only writer. Never edit `state.json`/`state.js` by hand: it holds a lock and
  writes atomically, so the main session and subagents can update the same dashboard.
- Keep the task list honest: the count on the page must match your plan. When the plan changes,
  `task add` or `task set N skipped`, don't silently drop rows.
- Questions carry a real default you are acting on, phrased as the action ("Hold #466; land the
  rest"), not "wait for Sam".
- Links in `ship` are full URLs. Write issue and PR numbers as `#123` anywhere (titles, details,
  questions, log); the page links them to the repo's GitHub (from `origin`).
- Record dependencies whenever work has an order, so the Flow panel is honest about what can run
  in parallel.
- Renderer changes go in `assets/index.html`; every dashboard picks them up on its next update.
