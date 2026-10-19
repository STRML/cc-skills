#!/usr/bin/env bash
# Fork arms of the fan-out benchmark (B: topic lenses, D: method lenses).
# Forks only exist in a live interactive session, so this opens a cmux pane running
# claude, pastes a recon-then-fork prompt, and waits for one report file per lens.
#
#   [STAGGER=1] [SRC_DIR="src/"] run-forks.sh <target-repo> <out-dir> <N> <set>
#
# <set> is a preset or a lenses.json set, as in run-headless.sh. Same model and
# flags as run-headless.sh. Out: <out-dir>/<lens>.jsonl, usage.txt.
# Exits non-zero, leaving <out-dir>/FAILED, if any lens fails to report in time.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
CLAUDE_BIN=${CLAUDE_BIN:-claude}
BENCH_MODEL=${BENCH_MODEL:-claude-sonnet-5-5}
# Profile directory: CLAUDE_CONFIG_DIR when set (its .claude.json lives inside it),
# otherwise ~/.claude with ~/.claude.json beside it.
config_dir=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
cfg=${CLAUDE_CONFIG_DIR:+$CLAUDE_CONFIG_DIR/.claude.json}
cfg=${cfg:-$HOME/.claude.json}
target=$(cd "$1" && pwd -P) out=$2 n=$3 set=$4
field() { python3 -I "$here/preset.py" "$set" "$@"; }
lenses=$(field lenses "$n")
src_dir=${SRC_DIR:-src/}
# The method and topic sets keep the exact wording of the measured review runs.
if [[ "$set" == method || "$set" == topic ]]; then
  recon="Read README.md and package.json, then read EVERY non-test .ts and .tsx file under src/ with the Read tool."
  task="Audit this repository for real bugs: behavior that is wrong for a user. Not style, not refactors."
  report_line='{"file": "src/...", "line": <number>, "title": "<short>", "why": "<what goes wrong, and when>"}'
  max=15 tail_note=" Report only bugs you can point to in the code." head_note=""
else
  if [[ $(field scope) == diff ]]; then
    # Without its diff the run would audit nothing and still count as complete.
    [[ -s "$target/CHANGES.diff" ]] || { echo "run-forks: $set reviews a diff; $target/CHANGES.diff is missing or empty" >&2; exit 1; }
    recon="Read README.md and the manifest, then read CHANGES.diff (the change set; the repository is at its post-change state), every file it touches in full, and the callers of each changed function."
  else
    recon="Read README.md and the manifest, then read EVERY non-test source file in $src_dir with the Read tool."
  fi
  extra=$(field recon_extra)
  [[ -n "$extra" ]] && recon="$recon Then: $(tr '\n' ' ' <<< "$extra")"
  task=$(field task) report_line=$(field report_line) max=$(field max_findings) tail_note=""
  # A fork inherits the launch message and can act as the launcher (seen once: three
  # of four forks each launched another fork and never reported).
  head_note="You are one of the forks, not the session that launched them: do not launch agents. "
fi

# A reused output directory would mix two runs' reports in one score.
if [[ -e "$out" ]] && [[ -n "$(ls -A "$out")" ]]; then
  echo "run-forks: $out is not empty; pick a new output directory" >&2
  exit 1
fi
mkdir -p "$out"
# Reports go to a fresh directory of our own inside the target, removed at the end.
bench=$(mktemp -d "$target/.fanout-bench.XXXXXX")
bench_rel=$(basename "$bench")

# The launcher path is the one string the pane's shell parses, so it must be plain:
# created under /tmp (not $TMPDIR, which can hold anything) and checked.
prompt=$(mktemp) launcher=$(mktemp /tmp/fanout-launch.XXXXXX) surface=""
[[ "$launcher" =~ ^[A-Za-z0-9/._-]+$ ]] || { echo "run-forks: unsafe launcher path: $launcher" >&2; exit 1; }
cleanup() {
  rm -f "$prompt" "$launcher"
  rm -rf "$bench"
  if [[ -n "$surface" ]]; then
    cmux close-surface --surface "$surface" --workspace "$CMUX_WORKSPACE_ID" --force > /dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

{
  cat << EOF
This is a benchmark run. Follow these phases exactly.

Phase 1, recon. Facts only: do not judge code quality or name suspected bugs, in your text or anywhere else. $recon Afterwards write one line listing how many files you read.

$(if [[ "${STAGGER:-0}" == 1 ]]; then
  echo "Phase 2, fan out in two steps. First launch ONLY the first lens below as one Agent call with subagent_type \"fork\" in the background. As soon as that call has been accepted, in your NEXT message launch the remaining $((n - 1)) lenses as Agent calls with subagent_type \"fork\", all in that one message. Give each fork this prompt, with its lens and id filled in:"
else
  echo "Phase 2, fan out. In ONE message, launch exactly $n Agent calls with subagent_type \"fork\", one per lens below. Give each fork this prompt, with its lens and id filled in:"
fi)

"$head_note$task You already have the source in context from the recon; read more only if you need to. Your lens: <LENS>.$tail_note Write ONLY JSON lines, one per finding, no prose, to $bench_rel/<ID>.jsonl with the Write tool: $report_line. At most $max findings, strongest first. Your text output is not visible to anyone; only the file counts. Then stop."

Lenses:
EOF
  while IFS=$'\t' read -r id brief; do echo "- id $id: $brief"; done <<< "$lenses"
  cat << EOF

Phase 3. When all $n files exist in $bench_rel/, reply with exactly: BENCH-DONE
EOF
} > "$prompt"

# The pane's shell may be fish or zsh, so it only ever runs `bash <launcher>`; every
# path and flag lives in the launcher, quoted for bash with %q.
printf 'cd %q && CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 exec %q --model %q --effort medium --settings %q --strict-mcp-config\n' \
  "$target" "$CLAUDE_BIN" "$BENCH_MODEL" '{"disableAllHooks":true}' > "$launcher"

project_dir="$config_dir/projects"
# Interactive claude stops at the folder-trust prompt in a directory it has never
# opened; headless -p runs skip that check, so the fork arm must pre-trust.
if [[ -f "$cfg" ]]; then
  tmp=$(mktemp "$cfg.XXXXXX")
  jq --arg d "$target" '.projects[$d].hasTrustDialogAccepted = true' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
fi
started=$(date +%s)
pane=$(cmux new-pane --workspace "$CMUX_WORKSPACE_ID" --direction down --focus false --command "bash $launcher")
# "OK surface:N pane:N ..." or "OK <surface-uuid> <workspace-uuid>": the surface is token 2.
surface=$(awk '/^OK/ {print $2; exit}' <<< "$pane")
[[ -n "$surface" ]] || { echo "run-forks: could not parse a surface from: $pane" >&2; exit 1; }
screen() { cmux read-screen --surface "$surface" --workspace "$CMUX_WORKSPACE_ID" --lines 40 2> /dev/null; }
# Paste only once claude's input box is up; a paste sent earlier is lost.
for _ in $(seq 1 30); do screen | grep -q 'shift+tab to cycle' && break; sleep 2; done
# Paste once: a retry after a slow render queues the whole benchmark twice. Delivery
# shows as the prompt itself (collapsed to "[Pasted text #1 +N lines]" when long),
# or, once claude is working and the prompt has scrolled off, as tool calls (⏺) or
# the "esc to interrupt" footer.
cmux paste --surface "$surface" --workspace "$CMUX_WORKSPACE_ID" --submit - < "$prompt" > /dev/null \
  || { echo "run-forks: cmux paste failed" >&2; exit 1; }
delivered=0
for _ in $(seq 1 15); do
  screen | grep -q -E 'Phase 1|Pasted text|⏺|esc to interrupt' && { delivered=1; break; }
  sleep 2
done
[[ $delivered -eq 1 ]] || { echo "run-forks: prompt never reached the pane" >&2; exit 1; }

failed=0
deadline=$((started + 1200))
while [[ $(find "$bench" -name '*.jsonl' | wc -l) -lt $n ]]; do
  if [[ $(date +%s) -ge $deadline ]]; then
    echo "run-forks: timed out with $(find "$bench" -name '*.jsonl' | wc -l)/$n reports" >&2
    failed=1
    break
  fi
  sleep 10
done
sleep 5
wall=$(($(date +%s) - started))
cp "$bench"/*.jsonl "$out/" 2> /dev/null || true

# The session transcript: the newest session in this project that spawned subagents.
# Headless runs write transcripts to the same folder, so "newest .jsonl" is not enough.
slug=${target//[^A-Za-z0-9]/-}
session=$(ls -td "$project_dir/$slug"/*/subagents 2> /dev/null | head -1)
transcript=${session:+$(dirname "$session").jsonl}
echo "wall=${wall}s transcript=$transcript" | tee "$out/usage.txt"
[[ -n "$transcript" ]] && python3 -I "$here/../scripts/usage.py" "$transcript" | tee -a "$out/usage.txt"
for f in "$out"/*.jsonl; do echo "$(basename "$f" .jsonl) findings=$(grep -c '^\s*{' "$f" || true)"; done
if [[ $failed -eq 1 ]]; then
  : > "$out/FAILED"
  exit 1
fi
