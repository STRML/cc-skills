# PR-watch v1 setup

Scope: autodream and omp-classifier (public, highest volume).

1. **Make the skill reachable.** The routine clones its repos, so list `STRML/cc-skills` as one of the routine's repos (or copy `skills/pr-review/` into each watched repo's `.claude/skills/`; the skill reads repo rules from the base ref, so a PR cannot rewrite it either way). Merge this skill to `main` first.
2. **Install the Claude GitHub App** (https://github.com/apps/claude) on the watched repos. It is what delivers the `pull_request` events to the routine.
3. **Create one routine** at claude.ai/code/routines.
   - Repos: autodream, omp-classifier, plus `STRML/cc-skills` for the skill.
   - Prompt: contents of `routine-prompt.md`.
   - Triggers (GitHub event, per repo): `pull_request.opened`, `pull_request.reopened`, `pull_request.synchronize`, `pull_request.ready_for_review`. Filters: Is draft = false; Author is not one of `dependabot[bot]`, `app/dependabot`. The skill skips fork PRs itself.
   - Connectors and secrets: none. Notifications: push to phone. Skipped events also notify; that is acceptable at ~4 PRs a day, and the `SKIPPED:` line is the whole message.
4. **Check the unconfirmed limits** on the routine page: whether one routine can hold triggers for several repos, and the hourly GitHub-event caps. If one routine cannot cover both repos, make one routine per repo with the same prompt.
5. **Smoke test** on a throwaway PR in autodream:
   - One session starts, a review arrives, nothing is posted to the PR and no commit, label or comment appears.
   - Push a second commit: a second review at the new SHA. Resolved/still-open lines read `n/a`, because reviews are not stored (see below).
   - Push two commits quickly: the first event's review is `SKIPPED: stale head`.
   - Open a PR as a draft, then mark it ready: a review starts.

## What "read-only" means here

Read-only is enforced by the prompt, the skill's rules, and the routine having no connectors or secrets. It is **not** enforced by a scoped token: the Claude GitHub App normally holds write permissions on the repos it is installed on, and the session's git credentials are not something this skill can remove. Treat the guarantee as prompt-level until you have confirmed otherwise in the routine's permission settings. The smoke test above only shows the reviewer behaved, not that it could not misbehave.

## Not stored

Reviews are returned to you, not written anywhere. So there is no ledger: the "already reviewed" guard only catches reviews you paste into a PR comment, and Resolved/Still open appears only if a prior review is in the event or the PR comments. Add a ledger when you want automatic delta reviews.

Deferred on purpose: the relay (all-repos coverage), ledger repo, persistent per-repo sessions, router, persona fan-out, Runner, comment posting, private repos, fork PRs, rush-marketing-bot integration.
