---
name: coderabbit-new
description: "Use when checking a PR for new CodeRabbit review comments since a specific commit. Triggers: 'coderabbit new comments', 'new review comments', 'what did coderabbit say', 'check coderabbit', 'filter pr comments'."
---

# CodeRabbit New Comments

Fetch CodeRabbit feedback added since a specific commit SHA and address ALL of it. Default goal: take the PR all the way to a green CodeRabbit verdict, not just resolve the loud ones.

## Why fix everything

CodeRabbit posts feedback in three buckets, all visible in the GitHub UI:

1. **Actionable comments** — line-level comments with `Potential issue` / severity badges. Block PR-green when present.
2. **Nitpick comments** — line-level OR collapsed in the review body under `🧹 Nitpick comments`. Trivial style/naming/clarity. Don't block merge by themselves but the review state stays `COMMENTED` (not `APPROVED`) until they're handled.
3. **Duplicate / outside-diff-range comments** — collapsed in the review body. Usually re-flag a previous round's finding that wasn't fully resolved.

Skipping nitpicks leaves CodeRabbit yellow indefinitely. If the user's goal is a green PR, you must address every one — even the trivial renames.

## What to Do

1. Get the PR number and the "since" commit SHA (usually the last commit you pushed before the review you've already addressed):
   ```bash
   git log --oneline -10
   ```

2. Resolve the timestamp the SHA was pushed:
   ```bash
   gh api repos/<owner>/<repo>/commits/<sha> --jq '.commit.committer.date'
   ```

3. Fetch line-level comments AND review-summary bodies created after that timestamp. Both matter — nitpicks often live ONLY in the summary body:
   ```bash
   SINCE="2026-04-26T22:26:18Z"
   # Line-level comments (actionable + line-level nitpicks)
   gh api "repos/<owner>/<repo>/pulls/<pr>/comments?per_page=100" --paginate \
     --jq "[.[] | select(.user.login | test(\"coderabbit|coderabbitai\"; \"i\")) | select(.created_at > \"$SINCE\") | {path, line, original_line, body, created_at}]" \
     > /tmp/cr-line.json
   # Review summaries (state + body containing nitpick/duplicate sections)
   gh api "repos/<owner>/<repo>/pulls/<pr>/reviews?per_page=100" --paginate \
     --jq "[.[] | select(.user.login | test(\"coderabbit|coderabbitai\"; \"i\")) | select(.submitted_at > \"$SINCE\") | {state, submitted_at, body}]" \
     > /tmp/cr-reviews.json
   ```

4. Wait for the review to be fully posted before fetching. CodeRabbit drips comments out over 1–3 minutes after a push. The review-summary object lands LAST (it's the "Actionable comments posted: N" message). Block until at least one review summary exists for the new push:
   ```bash
   until [ "$(gh api 'repos/<owner>/<repo>/pulls/<pr>/reviews?per_page=100' --paginate \
       --jq "[.[] | select(.user.login | test(\"coderabbit|coderabbitai\"; \"i\")) | select(.submitted_at > \"$SINCE\")] | length")" -gt 0 ]; do
     sleep 20
   done
   ```

5. Verify each finding against the current code (CR sometimes re-flags lines you already fixed). For each genuine issue:
   - **Actionable comments** — fix and add a regression test.
   - **Nitpick comments** — fix. If you disagree, leave a one-line PR comment explaining why; do not silently skip.
   - **Duplicate comments** — usually means your previous fix was incomplete; revisit.
   - **Outside-diff-range** — same triage as line-level; CR flags these when the cited file changed elsewhere.

6. Commit per round with a conventional message naming the round (`fix(scope): CR review round-N — N findings`). Pushing reopens the cycle; loop until CR posts a summary with `state: APPROVED` and either zero new comments or only "LGTM" prose.

## Parsing the review-summary body

Nitpicks and duplicates are inside collapsed `<details>` blocks in the review body, e.g.:

```
🧹 Nitpick comments (1)
  rush-vacuum/orchestrator/api/routes.py (1)
    1448-1450: Rename `real_cars` to `real_car` for accuracy.
    The query uses .scalars().first() ...
```

The format is stable. Read the full body with `jq -r '.[].body'` and grep for `Nitpick`, `Duplicate`, or `Outside diff range` headings to extract the per-file blocks.

## Stopping conditions

You're done when one of these is true:
- Latest CR review state is `APPROVED` AND no new line-level comments since the last push.
- The only remaining items are stylistic preferences you've explicitly decided not to take, with one-line PR replies explaining why.

A `COMMENTED` state with only nitpicks is NOT done — keep iterating.

## Shortcut for Common Case

All unresolved CodeRabbit feedback on a PR (every round, no since-filter):
```bash
gh api repos/<owner>/<repo>/pulls/<pr>/reviews \
  --jq '[.[] | select(.user.login | test("coderabbit|coderabbitai"; "i")) | {state, submitted_at, body}]'
```
