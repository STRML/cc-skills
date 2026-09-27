---
name: commit-and-verify
description: Pre-commit verification workflow. Use before any commit to ensure tests pass, linting is clean, and the commit message is meaningful. Replaces manual "commit" requests with a verified workflow. Triggers — "commit", "push", "ship it", "ship", "commit and push", "ready to commit/push". Invoke on intent to ship, not at commit time.
version: "1.2.0"
---

# Commit and Verify

Never commit blind. Always verify quality first.

## First: which repo?

The probes below run in the **session working directory**, which is frequently not the
repo being committed. In Claude Code the shell cwd resets to the launch directory after
every command, so `cd <repo> && git commit` does not persist either.

If a probe reports `NOT-A-REPO`, or the user named a repo elsewhere, set `REPO` to that
absolute path and prefix **every** git command in this skill with `git -C "$REPO"`:

```bash
REPO=/absolute/path/to/repo
git -C "$REPO" status --porcelain
```

An empty or `NOT-A-REPO` probe means "look elsewhere", not "nothing to commit". Do not
skip the skill because the probes came back empty, and do not try to `cd` your way out.

## Workflow

**1. Check for pre-commit hooks** (Husky, lint-staged, etc.)
- If hooks run tests/lint on commit, **skip manual test/lint runs** — they'll be duplicated.
- If no hooks, run tests and lint in parallel before staging.

**2. Review changes**

### git status
!`git rev-parse --git-dir >/dev/null 2>&1 && git status 2>&1 || echo "NOT-A-REPO: $PWD is not a git repository. Set REPO to the target repo and use 'git -C \"\$REPO\"' for every git command below."`

### git diff (staged + unstaged)
!`git rev-parse --git-dir >/dev/null 2>&1 && git diff HEAD 2>&1 | head -200 || echo "(skipped: not a git repository in cwd)"`

Check for: debug code (`console.log`, `debugger`), secrets/credentials, unintended files.

**3. Fix failures before committing**
- Tests fail → fix, re-run, confirm passing
- Lint fails → run `--fix`, fix remainder, confirm clean
- Never commit broken code

**4. Stage selectively and commit — the skill owns this step**

Once invoked, drive the commit through to completion here; do NOT hand back to a manual
`git add`/`git commit` afterward (CLAUDE.md: "the skill owns the commit").

```bash
git add <specific-files>   # never `git add .`
git commit -m "<type>: <description>" -m "<optional body: why, not what>"
```

Use **repeated `-m` flags** (one per paragraph) — NOT a `<<EOF` heredoc. The sandbox
blocks heredocs, and a blocked heredoc is the #1 cause of falling back to a manual
`git commit -F /tmp/...`, which is the bypass this skill exists to prevent. If the body
is long or multi-paragraph, write it with the **Write tool** to a temp file and
`git commit -F <file>` — still no heredoc, no `cat`/`sed` hacks.

**5. Push only if explicitly requested**

### Recent commits (match style)
!`git rev-parse --git-dir >/dev/null 2>&1 && git log --oneline -5 2>&1 || echo "(skipped: not a git repository in cwd — run 'git -C \"$REPO\" log --oneline -5')"`

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
