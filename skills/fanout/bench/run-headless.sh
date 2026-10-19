#!/usr/bin/env bash
# Headless arms of the fan-out benchmark: fresh agents with no shared recon.
#
#   run-headless.sh <target-repo> <out-dir> single [set]
#   run-headless.sh <target-repo> <out-dir> fresh <N> <set>
#
# single: one agent, every lens at once (arm A). <set> defaults to method.
# fresh:  N agents in parallel, one lens each, each starting from nothing (arm C).
# <set> is a preset (review, cleanup, simplify, security) or a lenses.json set
# (topic, method); see preset.py. A diff-scope preset audits CHANGES.diff at the
# target's root. BENCH_TOOLS overrides the agents' tools. Default: read-only for
# method/topic (the measured review runs), plus Bash for presets, whose recon steps
# run tools (cleanup's dead-code and cycle scanners) as a forked session can.
# Each agent's raw JSON goes to <out-dir>/<lens>.json; findings to <out-dir>/<lens>.jsonl.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
CLAUDE_BIN=${CLAUDE_BIN:-claude}
BENCH_MODEL=${BENCH_MODEL:-claude-sonnet-5-5}
target=$1 out=$2 arm=$3
case "$arm" in
  single) set=${4:-method} ;;
  fresh) n=$4 set=$5 ;;
  *) echo "run-headless: unknown arm $arm" >&2; exit 1 ;;
esac
measured_set=0
[[ "$set" == method || "$set" == topic ]] && measured_set=1
if [[ $measured_set -eq 1 ]]; then BENCH_TOOLS=${BENCH_TOOLS:-Read Grep Glob}; else BENCH_TOOLS=${BENCH_TOOLS:-Read Grep Glob Bash}; fi
field() { python3 -I "$here/preset.py" "$set" "$@"; }
task=$(field task) report_line=$(field report_line) max=$(field max_findings) scope=$(field scope)
recon_extra=$(field recon_extra)
# A diff-scope run without its diff would audit nothing and pass as "no findings".
if [[ "$scope" == diff && ! -s "$target/CHANGES.diff" ]]; then
  echo "run-headless: $set reviews a diff; $target/CHANGES.diff is missing or empty" >&2
  exit 1
fi
# A reused output directory would mix two runs' reports in one score.
if [[ -e "$out" ]] && [[ -n "$(ls -A "$out")" ]]; then
  echo "run-headless: $out is not empty; pick a new output directory" >&2
  exit 1
fi
mkdir -p "$out"

# The method and topic sets keep the exact wording of the measured review runs.
audit_prompt() {
  if [[ $measured_set -eq 1 ]]; then
    cat << EOF
Audit the repository in the current directory for real bugs: behavior that is wrong for a user. Not style, not refactors.
Your lens: $1
Report only bugs you can point to in the code. Output ONLY JSON lines, one per finding, no prose and no code fence:
{"file": "src/...", "line": <number>, "title": "<short>", "why": "<what goes wrong, and when>"}
At most 15 findings, strongest first.
EOF
    return
  fi
  local diff_note="" prep=""
  [[ "$scope" == diff ]] && diff_note="The change set to review is CHANGES.diff in the current directory; the repository is at its post-change state."
  [[ -n "$recon_extra" ]] && prep="Before you start: $(tr '\n' ' ' <<< "$recon_extra")"
  cat << EOF
$task
$diff_note
$prep
Your lens: $1
Output ONLY JSON lines, one per finding, no prose and no code fence:
$report_line
At most $max findings, strongest first.
EOF
}

run_agent() {
  local id=$1 brief=$2 rc=0
  ( cd "$target" && CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 "$CLAUDE_BIN" -p \
      --model "$BENCH_MODEL" --effort medium \
      --settings '{"disableAllHooks":true}' --strict-mcp-config \
      --allowedTools "$BENCH_TOOLS" --output-format json \
      "$(audit_prompt "$brief")" < /dev/null > "$out/$id.json" 2> "$out/$id.err" ) || rc=$?
  # A failed agent must not pass as "found nothing": a non-zero exit, output that is
  # not the CLI's result JSON, or a result flagged is_error all mark the run failed.
  # (Seen once: concurrent launches on one profile all exited empty with no error.)
  if [[ $rc -ne 0 ]] || ! jq -e '(.is_error | not) and (.result | type == "string")' "$out/$id.json" > /dev/null 2>&1; then
    echo "run-headless: agent $id failed (exit $rc); see $out/$id.err and $out/$id.json" >&2
    : > "$out/$id.FAILED"
    return 0
  fi
  jq -r '.result' "$out/$id.json" | grep -E '^\s*\{' > "$out/$id.jsonl" || true
  # Prose with no finding lines ("Audit unavailable") is a failed run, not a clean
  # one. Only an empty result counts as zero findings.
  if [[ ! -s "$out/$id.jsonl" ]] && jq -e '.result | test("\\S")' "$out/$id.json" > /dev/null 2>&1; then
    echo "run-headless: agent $id answered in prose, not findings; see $out/$id.json" >&2
    : > "$out/$id.FAILED"
  fi
}

if [[ "$arm" == single ]]; then
  run_agent all "$(field single)"
else
  while IFS=$'\t' read -r id brief; do
    run_agent "$id" "$brief" &
  done < <(field lenses "$n")
  wait
fi

if compgen -G "$out/*.FAILED" > /dev/null; then
  echo "run-headless: $(ls "$out"/*.FAILED | wc -l | tr -d ' ') agent(s) failed; this run is incomplete" >&2
  exit 1
fi

# One summary line per agent: findings, tokens, wall-clock, cost.
for f in "$out"/*.json; do
  jq -r --arg id "$(basename "$f" .json)" --arg n "$(wc -l < "${f%.json}.jsonl" | tr -d ' ')" \
    '"\($id)\tfindings=\($n)\tin=\(.usage.input_tokens)\tc_create=\(.usage.cache_creation_input_tokens)\tc_read=\(.usage.cache_read_input_tokens)\tout=\(.usage.output_tokens)\twall=\(.duration_ms/1000|floor)s\tcost=\(.total_cost_usd)"' "$f" 2> /dev/null \
    || echo "$(basename "$f" .json)	FAILED (see .err)"
done
