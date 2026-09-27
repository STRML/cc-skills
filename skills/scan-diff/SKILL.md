---
name: scan-diff
description: "Quick first-pass bug scan of a git diff for logic errors and security issues. Use when asked to scan or bug-check a diff; open-ended review of changes belongs to code-review."
---

# Scan Diff

Scan the current git diff for bugs, logic errors, and security issues using a focused Sonnet subagent (`model: "sonnet"`).

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

2. Pass it to a Sonnet subagent with this prompt:

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
