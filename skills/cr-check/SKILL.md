---
name: cr-check
description: Fetch or poll a CodeRabbit review on a GitHub PR and return ONLY the condensed, filtered findings (no analysis chains / prompt blocks / run-info). Use for any CodeRabbit (CR) question: what it said, looping on or re-requesting a review after a push, or gating a merge on the bot.
version: "1.3.0"
---

# cr-check — CodeRabbit PR findings

Use this instead of hand-parsing `gh api .../pulls/<n>/comments`. `scripts/cr-check.sh` (in this skill's directory) strips CodeRabbit's Analysis chain / Script executed / Web query / Prompt-for-AI-agents / Autofix / fingerprint noise and returns just the findings, typically under 5 KB. Needs `gh` and `jq`.

## Run it

```bash
<skill-dir>/scripts/cr-check.sh [PR#] [flags]
```

- `PR#` is optional; it is auto-detected from the current branch. Run it inside the repo (it uses `gh repo view`).
- After pushing a fix: `--wait` (blocks up to `--wait-seconds`, default 360). CodeRabbit re-reviews a push on its own; add `--trigger` only for a stuck state (see "Watch out" below).
- Long unattended polling: run it in the background (the script sleeps in 30 s loops).
- `--no-nitpicks` for quick triage; `--since <SHA>` for round-by-round; `--auto-resume` / `--retry-on-rate-limit` / `--retry-on-fair-usage` to recover paused, rate-limited or fair-usage-capped reviews.

## Exit codes (surface non-zero to the user)

- `0`: findings returned (or "no findings since SINCE")
- `2`: blocked by a status (`STATUS <kind>` printed): `PR_PAUSED`, `RATE_LIMIT`, `PLAN_LIMIT`, `FAIR_USAGE_LIMIT`, `ORG_DISABLED`, `MANUAL_TRIGGER_NOOP`, `UNKNOWN`. Don't auto-retry blindly.
- `3`: `--wait` deadline passed with no review
- `4`: precondition failed (no PR, not in a repo, missing `gh` or `jq`)
- `5`: a GitHub API call failed. Output may be partial and the status is UNKNOWN; never read it as "no findings" or approved.

## Output shape

```
PR #N — commit <sha> (<DECISION>) submitted <ts>
HEAD verdict: APPROVED|CHANGES_REQUESTED|DISMISSED|NONE on <sha> (<ts>)
PR reviewDecision: <GitHub's aggregate across all reviewers>
actionable: <n>

[path:line]
<severity ratings verbatim, e.g. ⚠️ Potential issue | 🟠 Major>
**Finding title**
<body + any suggested diff>

--- nitpicks (from review body) ---
```

Read the two verdict lines, not the header: the header shows only the newest review, and CodeRabbit posts a COMMENTED review for every thread reply, which can sit seconds after the APPROVED it hides. Pass severity ratings to the user verbatim. Treat it like any review: fix each actionable finding or push back with a concrete reason. Don't silently skip.

## `STATUS FAIR_USAGE_LIMIT`: wait it out, it's recoverable

CodeRabbit posted a **"Review limit reached"** callout: a temporary cap under its Fair Usage Limits Policy that states its own reset ("Next review available in: N minutes").

```bash
<skill-dir>/scripts/cr-check.sh <num> --trigger --retry-on-fair-usage
```

That sleeps the stated interval, re-triggers, and returns the real review. Without an explicit `--wait-seconds`, `--retry-on-fair-usage` raises the deadline to 100 minutes so one capped sleep fits. In practice the waits ran about 20 to 35 minutes and each ended in a complete review, one of which found four real bugs.

The re-trigger is mandatory, so this can't be a passive poll. A capped run is dropped, not queued: CodeRabbit "does not re-review already reviewed commits", so without an explicit `@coderabbitai review` after the timer it never revisits them. A plain `--wait` sits there forever.

> ⚠️ **A capped CodeRabbit still posts a PASSING status.** `gh pr checks` shows `CodeRabbit  pass` while `gh pr view --json reviews` is empty. It arrives through the legacy commit-status API (`context: CodeRabbit`, `state: success`), not check-runs. Never gate a merge on that check. Gate on a review object whose commit equals HEAD:
> ```bash
> gh pr view <num> --json reviews \
>   --jq '[.reviews[]|select(.author.login|test("coderabbit";"i"))|select(.commit.oid=="<HEAD_SHA>")]|last|.state'
> ```
> cr-check warns about this combination automatically.

When the wait is longer than the work can afford (the cap outlasts it, or re-trips; cr-check gives up after 5 waits), gate the merge on another review you trust on HEAD instead, and say which one in the merge body. Don't write "Reviewed by CodeRabbit (APPROVED)" when it wasn't. If a real CodeRabbit review lands first, address it too. The two catch different things, so when the wait is affordable, waiting for CodeRabbit as well is the more complete gate.

## Clearing the gate after CHANGES_REQUESTED

After pushing fixes, just wait: the incremental re-review runs automatically on a push. It only shows "Review skipped" after 5+ pushes since the last review. If the review is paused, `gh pr comment <PR#> --body "@coderabbitai resume"`; don't escalate to a full review for that. `@coderabbitai full review` re-reads the whole PR; reserve it for a stuck gate (no review lands on HEAD after waiting, or the aggregate decision stays wedged despite a clean incremental pass), and never after an APPROVED.

Loop to get to APPROVED:

1. Push fixes, then `cr-check --wait` (or poll until the latest review's commit equals HEAD). The incremental review arrives on its own.
2. If it's paused: `@coderabbitai resume`. If skipped (5+ pushes) or wedged: `@coderabbitai review` (incremental) before reaching for `full review`.
3. Resolve stale inline threads whose line didn't change. They don't auto-outdate and can keep the decision stuck. Pass GraphQL as a file (`gh api graphql -F query=@q.graphql`) so the shell doesn't mangle `{}` and `()`:
   - query: `reviewThreads(first:50){nodes{id isResolved path line}}`, then keep `isResolved==false`
   - mutation: `resolveReviewThread(input:{threadId:"PRRT_..."}){thread{isResolved}}`
4. Profile note: some review profiles post APPROVED directly on a clean pass. The CHILL profile posts COMMENTED, so a stale CHANGES_REQUESTED must be dismissed with `gh api -X PUT repos/<o>/<r>/pulls/<n>/reviews/<id>/dismissals -f message=... -f event=DISMISS`.

## Watch out

- **Do not fire `@coderabbitai review` after an ordinary push.** The incremental review already runs. A redundant trigger starts a second, parallel review that pins the "CodeRabbit" status check to pending, flips `mergeStateStatus` to UNSTABLE and blocks a clean merge for minutes, even though `reviewDecision` already reads APPROVED. Trigger only for a real stuck state: draft to ready (CodeRabbit skips drafts), "Review skipped" after 5+ pushes, or a verified pause (then prefer `@coderabbitai resume`). When in doubt, `cr-check --wait`.
- A bot APPROVED on commit N does not extend to commit N+1. GitHub keeps `reviewDecision=APPROVED` across a push, but the bot hasn't seen the new code. Get the approval onto the actual HEAD before claiming the bot approved HEAD.
- The review body can carry "Outside diff range" findings that cr-check won't inline. Also read `gh pr view <n> --json reviews --jq '.reviews|last|.body'` before declaring zero findings.
