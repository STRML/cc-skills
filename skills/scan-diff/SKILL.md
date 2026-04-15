---
name: scan-diff
description: "Use when scanning a git diff for bugs, logic errors, or security issues. Triggers: 'scan diff', 'check diff for bugs', 'review my changes', 'bug scan', 'scan for bugs'."
---

# Scan Diff

Scan the current git diff for bugs, logic errors, and security issues using a focused haiku subagent.

## Usage

Run from any git repo. By default scans staged + unstaged changes vs HEAD:

```bash
git diff HEAD
```

Or scan a specific commit range:
```bash
git diff <base>..<head>
```

Or scan only staged changes:
```bash
git diff --cached
```

## What to Do

1. Get the diff:
   ```bash
   git diff HEAD
   ```

2. Pass it to a haiku subagent with this prompt:

   > You are a focused bug scanner. Review this git diff for: bugs and logic errors, off-by-one errors, null/undefined access, error handling gaps, security issues (injection, auth bypass, insecure defaults), and race conditions. Be terse. Only report issues you're confident about. Skip style issues. For each issue: file:line, one sentence description, suggested fix.
   >
   > ```diff
   > <paste diff here>
   > ```

3. Report findings inline. If no issues found, say so explicitly.

## Notes

- Skip purely mechanical changes (imports, formatting, renames) — focus on logic
- For large diffs (>500 lines), split by file and scan separately
- This is a quick first-pass — not a substitute for full code review
