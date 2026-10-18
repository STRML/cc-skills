#!/usr/bin/env bash
# Headless arms of the fan-out benchmark: fresh agents with no shared recon.
#
#   run-headless.sh <target-repo> <out-dir> single
#   run-headless.sh <target-repo> <out-dir> fresh <N> <topic|method>
#
# single: one agent, every lens at once (arm A).
# fresh:  N agents in parallel, one lens each, each starting from nothing (arm C).
# Each agent's raw JSON goes to <out-dir>/<lens>.json; findings to <out-dir>/<lens>.jsonl.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
CLAUDE_BIN=${CLAUDE_BIN:-claude}
BENCH_MODEL=${BENCH_MODEL:-claude-sonnet-5-5}
target=$1 out=$2 arm=$3
mkdir -p "$out"

audit_prompt() {
  cat << EOF
Audit the repository in the current directory for real bugs: behavior that is wrong for a user. Not style, not refactors.
Your lens: $1
Report only bugs you can point to in the code. Output ONLY JSON lines, one per finding, no prose and no code fence:
{"file": "src/...", "line": <number>, "title": "<short>", "why": "<what goes wrong, and when>"}
At most 15 findings, strongest first.
EOF
}

run_agent() {
  local id=$1 brief=$2
  ( cd "$target" && CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 "$CLAUDE_BIN" -p \
      --model "$BENCH_MODEL" --effort medium \
      --settings '{"disableAllHooks":true}' --strict-mcp-config \
      --allowedTools "Read Grep Glob" --output-format json \
      "$(audit_prompt "$brief")" < /dev/null > "$out/$id.json" 2> "$out/$id.err" ) || true
  jq -r '.result // ""' "$out/$id.json" | grep -E '^\s*\{' > "$out/$id.jsonl" || true
  # An agent that returned nothing must not pass as "found nothing" (seen once:
  # concurrent launches on one profile all exited empty with no error).
  if [[ ! -s "$out/$id.json" ]]; then
    echo "run-headless: agent $id returned no output; see $out/$id.err" >&2
    : > "$out/$id.FAILED"
  fi
}

case "$arm" in
  single)
    run_agent all "$(jq -r '.single.brief' "$here/lenses.json")"
    ;;
  fresh)
    n=$4 set=$5
    while IFS=$'\t' read -r id brief; do
      run_agent "$id" "$brief" &
    done < <(jq -r --arg s "$set" --argjson n "$n" '.[$s][:$n][] | [.id, .brief] | @tsv' "$here/lenses.json")
    wait
    ;;
  *) echo "run-headless: unknown arm $arm" >&2; exit 1 ;;
esac

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
