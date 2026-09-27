---
name: coderabbit-new
description: "Use when the goal is to take a PR to a CodeRabbit APPROVED verdict by addressing every finding, nitpicks and duplicates included, round after round. Triggers: 'address all coderabbit comments', 'fix every CR nitpick', 'get coderabbit to approve', 'clear coderabbit'. For fetching or reading a CodeRabbit review, use cr-check."
---

# CodeRabbit: address every finding

Take a PR to a green CodeRabbit verdict by handling ALL of its feedback, not just the loud items. This skill sets the policy. The `cr-check` skill (`~/.claude/scripts/cr-check.sh`) does all fetching and waiting; do not hand-parse `gh api` output or write a `sleep` loop.

## Why fix everything

CodeRabbit posts feedback in three buckets, all visible in the GitHub UI:

1. **Actionable comments**: line-level comments with `Potential issue` / severity badges. They block a green PR.
2. **Nitpick comments**: line-level, or collapsed in the review body under `🧹 Nitpick comments`. Trivial style, naming, clarity. They don't block merge by themselves, but the review state stays `COMMENTED` (not `APPROVED`) until they're handled.
3. **Duplicate / outside-diff-range comments**: collapsed in the review body. They usually re-flag an earlier finding that wasn't fully resolved.

Skipping nitpicks leaves CodeRabbit yellow indefinitely. When the goal is a green PR, address every one, even the trivial renames.

## What to do

1. Find the "since" commit: the last commit you pushed before the review you already addressed (`git log --oneline -10`).

2. Fetch the findings since it, waiting for the review to land:
   ```bash
   ~/.claude/scripts/cr-check.sh <pr> --since <sha> --wait
   ```
   CodeRabbit drips comments over 1–3 minutes after a push, and `--wait` blocks until the review settles. For a long wait, run it with `run_in_background: true`. Handle non-zero exits as the `cr-check` skill describes.

3. Also read the latest review body, which carries "Outside diff range" and duplicate blocks that cr-check may not inline:
   ```bash
   gh pr view <pr> --json reviews --jq '.reviews|last|.body'
   ```

4. Verify each finding against the current code (CR sometimes re-flags lines you already fixed). For each genuine issue:
   - **Actionable comments**: reproduce with a failing test first, then fix.
   - **Nitpick comments**: fix. If you disagree, leave a one-line PR comment explaining why; do not silently skip.
   - **Duplicate comments**: your previous fix was usually incomplete; revisit it.
   - **Outside-diff-range**: same triage as line-level; CR flags these when the cited file changed elsewhere.

   Fix each finding as a class: search for its siblings and fix every hit in the same push.

5. Commit each round with a conventional message naming the round (`fix(scope): CR review round-N — N findings`), through the `commit-and-verify` skill. Pushing starts the next round; go back to step 2.

## Stopping conditions

You're done when one of these is true:
- The HEAD verdict line from cr-check reads `APPROVED` on HEAD AND no new line-level comments landed since the last push.
- The only remaining items are stylistic preferences you decided not to take, each with a one-line PR reply explaining why.

A `COMMENTED` state with only nitpicks is not done; run another round.

**Rounds end at three**, the same cap `~/.claude/docs/guardrails/review.md` § "Review rounds end at three" sets for the review scripts. If the third round still posts findings, stop, group every finding from every round by the mistake that produced it, name the step that would have caught each group in round 1, and report the groups and counts with a recommendation (merge with issues filed, one more round, or redesign). Sam decides.

If CodeRabbit cannot review (fair-usage cap, rate limit, wedged), follow the `cr-check` skill's fallback: a review script exiting 0 on HEAD approves the merge the same as CodeRabbit's APPROVED.
