---
name: coderabbit-new
description: "Use when checking a PR for new CodeRabbit review comments since a specific commit. Triggers: 'coderabbit new comments', 'new review comments', 'what did coderabbit say', 'check coderabbit', 'filter pr comments'."
---

# CodeRabbit New Comments

Fetch PR review comments and filter to only those added after a specific commit SHA — cuts through re-shown old comments.

## Usage

```bash
gh pr view <pr-number> --json reviews,comments
```

Or fetch review comments via API:
```bash
gh api repos/<owner>/<repo>/pulls/<pr-number>/comments \
  --jq '[.[] | select(.user.login | test("coderabbit|coderabbitai"; "i"))]'
```

## What to Do

1. Get the PR number and the "since" commit SHA (usually the last commit you pushed before asking for review):
   ```bash
   git log --oneline -5
   ```

2. Fetch all PR review comments:
   ```bash
   gh api repos/<owner>/<repo>/pulls/<pr>/comments > /tmp/pr-comments.json
   ```

3. Filter to comments created after your commit was pushed. Since GitHub doesn't expose commit SHA per comment directly, filter by `created_at` timestamp — find when your commit was pushed:
   ```bash
   gh api repos/<owner>/<repo>/commits/<sha> --jq '.commit.committer.date'
   ```

4. Filter comments newer than that timestamp:
   ```bash
   gh api repos/<owner>/<repo>/pulls/<pr>/comments \
     --jq --arg since "2026-03-07T12:00:00Z" \
     '[.[] | select(.created_at > $since) | {path: .path, line: .line, body: .body}]'
   ```

5. Report only actionable comments. Skip:
   - Nitpicks and style suggestions
   - Comments on lines you've already changed
   - "Consider" / "might want to" suggestions unless there's a clear bug

## Shortcut for Common Case

If you just want all unresolved CodeRabbit comments on a PR:
```bash
gh api repos/<owner>/<repo>/pulls/<pr>/reviews \
  --jq '[.[] | select(.user.login | test("coderabbit"; "i")) | {state: .state, body: .body, submitted_at: .submitted_at}]'
```
