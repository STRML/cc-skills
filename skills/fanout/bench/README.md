# fanout benchmark

How `/fanout`'s design was chosen, and how to rerun the measurement on your own repo.

## Result

Forked lenses, launched staggered, found 2.7× as many real issues per run as a single agent at about the same cost per issue, and cost 59% of the same lenses run as fresh agents.

| Configuration | Runs | Real issues per run | Cost per run | $ per issue |
|---|---|---|---|---|
| single agent, every lens at once | 1 | 11 | $0.79 | $0.072 |
| 4 forks, topic lenses, launched together | 1 | 30 | $3.78 | $0.126 |
| 4 forks, topic lenses, staggered | 2 | 25 | $1.71 | $0.068 |
| 4 fresh agents, topic lenses | 1 | 20 | $1.68 | $0.084 |
| 8 fresh agents, topic lenses | 1 | 33 | $3.36 | $0.102 |
| 4 fresh agents, method lenses | 2 | 23 | $3.08 | $0.134 |
| **4 forks, method lenses, staggered** | **3** | **30** | **$1.82** | **$0.061** |
| 8 forks, method lenses, staggered | 1 | 38 | $2.66 | $0.070 |

Sonnet 5.5 at medium effort for every agent. 92 distinct real issues across all 12 runs.

## Other presets

Each preset ran as a single agent and as forks with a staggered launch: 2 runs of each, Sonnet 5.5 at medium effort. Codex judged every finding against the preset's own bar, its `task` and `keep_if` (`judge.py --preset`). Costs use the per-token rates fitted on the review runs.

| Preset | Corpus | Arm | Real per run | Cost per run | $ per issue |
|---|---|---|---|---|---|
| cleanup | react-grid-layout, ~70K tokens | single agent | 1.5 | $0.28 | $0.185 |
| | | **8 forks** | **45** | **$2.74** | **$0.061** |
| security | DVNA, ~70KB (~17K tokens) | single agent | 11.5 (11-12 of 19 documented) | $0.19 | $0.016 |
| | | 4 forks | 18.5 (15 of 19 documented) | $0.89 | $0.048 |
| simplify | a 1,206-line react-grid-layout diff | single agent | 7.5 | $0.23 | $0.031 |
| | | 5 forks | 14.5 | $0.83 | $0.057 |

Forking pays when the shared recon is big. On react-grid-layout's ~70K tokens, the cleanup forks found 45 valid proposals per run against 1.5 for one agent, at a third of the cost per proposal: the same shape as review. The single agent, given all eight concerns at once, wrote 9-16 proposals and most failed the bar. On DVNA and the diff there was little prefix to share, so each fork's own output dominated the cost: the forks still found more (security recall 15/19 against 11-12/19), but each issue cost 1.8-3× as much. Two single-agent runs found 13 distinct issues on each of those corpora, for about half the cost of one fork run or less. The break-even size lies somewhere between the two measured sizes, 17K and 70K tokens; the skill draws the line at 30K, which is a guess inside that range, not a measurement. Below it, run one agent, or fork only when coverage matters more than cost.

Precision against the preset bar was 31-32% for cleanup forks (6-22% single), 72-83% for security forks (80-93% single) and 41-45% for simplify forks (53-57% single). Forks trade some precision for coverage, which is why the host verifies every item before reporting or applying it.

One fork run failed in a way that changed the skill: three of four security forks inherited the launch message, acted as the launcher, each started another fork and ended without reporting. The fork prompt now opens with "You are one of the forks, not the session that launched them: do not launch agents." That run was discarded and rerun.

## What decided the design

**Launch one fork, then the rest.** Forks launched in one message each rebuilt the shared prefix: every fork's first request wrote ~154K cache tokens. Launched one-then-rest, forks 2..N read ~209K from cache and wrote under 1K. That cut the forks' cache writes 6.4× and the cost of an identical 4-fork run from $3.78 to $1.71.

```
launched together   fork first request: read  57K  write 154K   (each of 4)
one, then the rest  fork first request: read 209K  write <1K    (forks 2..4)
```

**Fork instead of fresh agents.** With the same method lenses, forks found 30 issues per run against 23 for fresh agents, at $1.82 against $3.08. Fresh agents each re-read the codebase; forks inherit it. Cost model from the measured parts of the method runs: forks = recon $0.94 + first fork $0.47 + $0.136 per later fork; fresh = $0.77 per agent. It reproduces the measured N=4 cost ($1.82). The two tie at N=2 and forks are cheaper from N=3; at N=8 the model gives $2.36 against $6.16 (the measured 8-fork run cost $2.66, since its forks wrote longer reports). With topic lenses, where each fresh agent reads less ($0.42), break-even moves to N=5.

**Diverge lenses by method, not by topic.** At equal replicate count (2 runs each), method-lens runs found 1.8-2.0 issues no other configuration found per 10 true findings; topic-lens forks found 1.4.

**Starting fresh does not buy coverage.** Forked and fresh method runs each missed about half of the other's issues (52% and 46%). Repeat runs of the identical forked configuration varied about as much: 28-33 issues each, 47 combined. The cheap route to more coverage is more forked lenses or a second forked batch.

**N=4 by default.** 8 forks found 38 issues against 30 for 4 (+27%) at +46% cost, and half of their true findings repeated another lens's.

## Caveats

- One repo (react-grid-layout, TypeScript, ~70K tokens of source), one model (Sonnet 5.5), one judge family (Codex). The other presets add DVNA and one react-grid-layout diff, with 2 runs per arm.
- DVNA is a well-known teaching app, so agents may recognize it; its `docs/`, which list the answers, were left out of the target. Its 19 documented vulnerabilities serve as the recall key.
- The cleanup single agent had Bash, like the forks, so it could run the dead-code and cycle scanners. The other headless arms were read-only.
- A diff-scope run cannot prove an agent read the diff; the runners only check that `CHANGES.diff` exists and is non-empty.
- 1-3 runs per configuration. Treat differences under ~5 issues per run as noise.
- "Real" is a judge verdict with a concrete-scenario requirement, not verified line by line. Review verdicts were spot-checked by hand on a sample. For cleanup, a hand check of all 25 single-agent verdicts and 6 accepted fork verdicts agreed with the judge on all but 2 (both rejected deletions of one unreferenced module), which would move the single agent from 1.5 to about 2.5 per run.
- Only DVNA fork run r1 had the "you are one of the forks" line; every other fork run predates it.
- Sizes in tokens are bytes divided by 4.
- Distinct issues are clustered by file and line distance (same file, within 10 lines), which can merge two nearby bugs or split one.
- Seeded recall did not separate configurations: every run found 2-5 of the 12 seeded bugs, and 5 seeded bugs were never found by any run. Several reverted fixes are hard to see as bugs without the original issue thread.
- Costs come from per-token rates fitted on 21 runs whose CLI reported both usage and cost (input $2, cache write $4, cache read $0.10, output $10 per million; the fit reproduced every reported cost). The break-even N assumes a model's rates scale together, so it should hold for other models; ds4 and other providers' caching was not measured.

## Rerun it

```bash
# 1. Seed a corpus: revert historical fix commits, export as a history-free repo.
bench/build-corpus.sh <repo> <pinned-sha> <out-dir> 12 <fix-sha...>
# 2. Run configurations.
bench/run-headless.sh <out>/target <out>/runs/A single
bench/run-headless.sh <out>/target <out>/runs/C-r1 fresh 4 method
STAGGER=1 bench/run-forks.sh <out>/target <out>/runs/D-r1 4 method   # needs cmux
# 3. Judge (Codex, blind to configuration), then score.
bench/judge.py <out> --strict --rematch
bench/analyze.py <out>
# A preset other than review: give the set name, judge against the preset's bar.
bench/run-headless.sh <out>/target <out>/runs/A-single-r1 single cleanup
STAGGER=1 bench/run-forks.sh <out>/target <out>/runs/D-fork8-r1 8 cleanup
bench/judge.py <out> --preset cleanup
bench/analyze.py <out> --rates-from <a corpus with 8+ headless runs>
```

For `simplify`, put the change set at `<out>/target/CHANGES.diff`. Corpora without seeded bugs take an `answer-key.json` of `[]`.

`scripts/usage.py <session>` prints any Claude Code session's per-subagent cache reads and writes; a fork's first-request columns show whether it hit the cache.
