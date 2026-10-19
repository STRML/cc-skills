---
description: Deep codebase cleanup via eight forked subagents that inherit this session's map of the repo, one per concern - dedup, type consolidation, dead code, circular deps, weak types, defensive-programming cruft, legacy paths, AI slop. Runs the fanout skill's cleanup preset. Forks only report; this session triages the reports and makes every edit, committing per concern.
---

# Code Cleanup

Run the `fanout` skill with the `cleanup` preset (`skills/fanout/presets/cleanup.json`), all eight lenses, over $ARGUMENTS if given and the whole repo otherwise.

```
recon once ─▶ fork 1 ─▶ forks 2..8 ─▶ 8 reports ─▶ this session triages
           ─▶ applies: legacy, dead code, cycles, types, dedup, weak types, defensive, slop
           ─▶ typecheck + tests + commit after each concern
```

The fanout skill holds the whole procedure: the recon, the staggered launch, the fork prompt, the triage and the apply order. Follow it as written; this command adds nothing to it.
