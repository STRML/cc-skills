---
name: commit-and-verify
description: Pre-commit verification workflow. Use before any commit to ensure tests pass, linting is clean, and the commit message is meaningful. Replaces manual "commit" requests with a verified workflow.
version: "1.1.0"
---

# Commit and Verify

Never commit blind. Always verify quality first.

## Workflow

**1. Check for pre-commit hooks** (Husky, lint-staged, etc.)
- If hooks run tests/lint on commit, **skip manual test/lint runs** — they'll be duplicated.
- If no hooks, run tests and lint in parallel before staging.

**2. Review changes**

### git status
!`git status 2>&1`

### git diff (staged + unstaged)
!`git diff HEAD 2>&1 | head -200`

Check for: debug code (`console.log`, `debugger`), secrets/credentials, unintended files.

**3. Fix failures before committing**
- Tests fail → fix, re-run, confirm passing
- Lint fails → run `--fix`, fix remainder, confirm clean
- Never commit broken code

**4. Stage selectively and commit**
```bash
git add <specific-files>   # never `git add .`
git commit -m "$(cat <<'EOF'
<type>: <description>

<optional body: why, not what>
EOF
)"
```

**5. Push only if explicitly requested**

### Recent commits (match style)
!`git log --oneline -5 2>&1`

## Commit Message Types

`feat` · `fix` · `refactor` · `style` · `docs` · `test` · `chore`

Good: `fix: prevent crash when user has no profile photo`
Bad: `update`, `fix stuff`, `WIP`

## Anti-Patterns

- Committing without verification
- `git add .` — be selective
- Vague messages
- Committing secrets
- Force-pushing to main without explicit request
