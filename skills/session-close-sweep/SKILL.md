---
name: session-close-sweep
description: "Run when the user signals the session is ending in any form (closing out, wrapping up, stopping for the day, asking what is left hanging or what else to add), or asks to close out or verify the issue tracker before stopping. Also run at a natural stopping point after multi-issue, production-writing, or multi-commit work. The audit: verify open issues against origin/main and production, close stale ones with evidence comments, batch human-decision issues, check git state (dirty tree, unpushed commits, leftover worktrees and stashes), flag docs the session contradicted, harvest scratch tools, gotchas, and rule fixes the session produced, and report what remains and why."
---

# Session close sweep

An end-of-session audit for a repo with a GitHub tracker (the `gh` CLI) and, where one exists, a reachable production environment. It verifies. It does not summarize. Every stale issue gets closed with evidence, every claim in a closing comment is checked against live state first, and anything that needs a human decision goes to the user as a question, never an inference.

Run it without asking when a session longer than about two hours concludes, before the final report. After a shorter session, end the final report with a yes/no offer to run it. Do not run it uninvited in the middle of a task.

## Procedure

1. **Scope, then enumerate.** List the repos this session wrote to: commits, pushes, issue or PR comments, edited files. That set is the scope, and the launch directory is not in it by default. A session launched in repo A that only edited dotfiles sweeps the dotfiles repo, not A's tracker. For each repo in scope, list all open issues, not only the ones touched this session:
   `gh issue list -R <owner/repo> --state open --json number,title,labels,updatedAt`
   Sort them into this-session threads, same-area threads, and unrelated. Steps 6 and 7 use the same scope.

2. **Verify each candidate against current reality, in this order:**
   - Read the issue body for stated acceptance criteria and options.
   - Check origin/main (does the code exist, did the migration land, what are the file dates?). Use origin/main, not a local checkout that may be stale.
   - Check production or runtime state when the issue's claim depends on it (an SSH probe, a curl, an API call).
   - When the live check and the code check can disagree (config values, deploy state, file mtimes), trust the live check.
   - An issue is stale if its work landed, its premise is now false, or its only remaining question was answered elsewhere.
   - An issue whose body frames a decision menu is waiting for its owner. Batch those into one question (step 4).

3. **Sweep in priority order:** this-session threads first (freshest provenance), then same-area threads, then the rest. If the list is long, present the same-area and this-session candidates and say why the others stay open instead of skipping them silently.

4. **Ask for human decisions in one batch.** Collect every issue where the disposition is the owner's call (wontfix or fix, now or later, keep open as a reminder) and put them together in one `AskUserQuestion` call, each with a recommended default. Never close a wontfix without the owner's word. Never mass-close policy-decision tickets: they are reminders, not debt.

5. **Close with evidence comments.** Each closing comment states:
   - what resolved the issue and when,
   - the verified fact and its source: a commit SHA, command output, a curl result, or an API response,
   - any follow-up work and where it lives (a file path or a new issue number).

   A close without a comment leaves no audit trail.

6. **Git loose ends:**
   - `git status --porcelain` for a dirty tree. Report everything: stash with a named message or commit, and list any stash left behind in the final output.
   - Unpushed commits on the working branch (`git log origin/<branch>..HEAD`).
   - Worktrees this session created (`.claude/worktrees/*`, `.worktrees/*`). Remove only those. Report foreign or host-owned worktrees and leave them alone.
   - Scratch files in `/tmp` that a committed script references (copied payloads, generated manifests). If a committed provenance comment points at a `/tmp` path, say where the durable copy lives.

7. **Doc drift.** If the session changed behavior that CLAUDE.md, codemaps, the README, or issue bodies describe, either update the doc now or name the contradiction in the report. Do not leave a doc claiming the old state.

8. **Harvest.** List what this session built or learned that disappears when it closes, and offer it as one batch with a recommendation:
   - Scripts, harnesses, and fixtures in the scratchpad or `/tmp` that answered a question someone will ask again. Move them somewhere durable (a scripts directory, the repo's `tools/`) and point to them from the doc a future session reads first.
   - Gotchas that cost a retry or a contaminated run. These belong in the project's gotcha or guideline docs, not only in memory.
   - Rules the session showed to be wrong or incomplete: an output style, skill, or agent brief whose output missed the mark. Fix the rule, then search for the same rule restated elsewhere.

9. **Report.** Two parts:
   - Closed: a table of issue, one-line reason, and the named evidence source.
   - Remains: a grouped list with one line on why each issue stays open (owner decision, needs focused work, deliberate reminder).

10. **Learning capture.** If the session produced a gotcha or convention that applies beyond the repo it happened in, suggest saving it with whatever learnings mechanism the user has (a `session-learnings` skill, a shared notes repo). A rule about one repo's code goes to that repo's CLAUDE.md in step 8 instead. If nothing qualifies, skip this step without comment. Make at most one suggestion and let the user decide.

## Traps

- A remote shell can mislabel root-protected files when you grep them (a config file readable only by root, for example). Grep the real file directly and check its mtime: a rename may have landed between the probe that filed the issue and now.
- An open issue that contains its own decision menu is waiting for its owner. Present it. Do not infer an answer.
- Closing an issue as "superseded" requires naming the commit or issue that supersedes it. "Seems done" is not evidence.
- An issue whose only remaining work is the owner's policy decision stays open. Batch those into the question in step 4.
- A stale-looking issue may have been updated after your last fetch. Re-read its body and comments before closing, and do not trust the title in the list view.
- Local checkouts can be behind or dirty. Verify claims against origin/main (`git show origin/main:<path>`), not the working tree.

## Companion skills

- A handoff skill, if you have one, for when a next session continues this work. That is continuation, where this skill is closure.
- A session-learnings skill, if you have one, for step 10.
