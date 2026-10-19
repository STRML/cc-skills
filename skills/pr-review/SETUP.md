# PR-watch v1 setup

Scope: autodream, omp-classifier, cc-ds4 (public, highest volume, cc-ds4 has outside authors).

1. **Make the skill reachable.** The routine clones its repos, so list `STRML/cc-skills` as one of the routine's repos (or copy `skills/pr-review/` into each watched repo's `.claude/skills/`). Merge this skill to `main` first.
2. **Install the Claude GitHub App** (https://github.com/apps/claude) on the three repos.
3. **Create one routine** at claude.ai/code/routines.
   - Repos: autodream, omp-classifier, cc-ds4 (plus the repo holding the skill, if separate).
   - Prompt: contents of `routine-prompt.md`.
   - Triggers (GitHub event, per repo): `pull_request.opened`, `pull_request.reopened`, `pull_request.synchronize`; filter Is draft = false; filter Author is not one of `dependabot[bot]`, `app/dependabot` (the skill skips forks itself).
   - Connectors and secrets: none. No environment secrets, no GitHub write tools, network limited if the environment allows it.
   - Notifications: on, push to phone.
4. **Check the unconfirmed limits** on the routine page: whether one routine can hold triggers for several repos, and the hourly GitHub-event caps. If one routine cannot cover all three, make one routine per repo with the same prompt.
5. **Smoke test.** Open a throwaway PR on cc-ds4 and confirm: one session starts, the review arrives, nothing is posted to the PR. Push a second commit and confirm a second review at the new SHA that lists resolved/still-open findings. Push two commits quickly and confirm the stale-head guard skips the first.

Deferred on purpose: the relay (all-repos coverage), ledger repo, persistent sessions, router, persona fan-out, Runner, comment posting, private repos, rush-marketing-bot integration.
