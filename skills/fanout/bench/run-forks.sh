#!/usr/bin/env bash
# Fork arms of the fan-out benchmark (B: topic lenses, D: method lenses).
# Forks only exist in a live interactive session, so this opens a cmux pane running
# claude, pastes a recon-then-fork prompt, and waits for one report file per lens.
#
#   run-forks.sh <target-repo> <out-dir> <N> <topic|method>
#
# Same model and flags as run-headless.sh. Out: <out-dir>/<lens>.jsonl, usage.txt.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
CLAUDE_BIN=${CLAUDE_BIN:-claude}
BENCH_MODEL=${BENCH_MODEL:-claude-sonnet-5-5}
# Profile directory: CLAUDE_CONFIG_DIR when set (its .claude.json lives inside it),
# otherwise ~/.claude with ~/.claude.json beside it.
config_dir=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
cfg=${CLAUDE_CONFIG_DIR:+$CLAUDE_CONFIG_DIR/.claude.json}
cfg=${cfg:-$HOME/.claude.json}
target=$1 out=$2 n=$3 set=$4
mkdir -p "$out"
rm -rf "$target/.bench"
mkdir -p "$target/.bench"

prompt=$(mktemp)
{
  cat << EOF
This is a benchmark run. Follow these phases exactly.

Phase 1, recon. Facts only: do not judge code quality or name suspected bugs, in your text or anywhere else. Read README.md and package.json, then read EVERY non-test .ts and .tsx file under src/ with the Read tool. Afterwards write one line listing how many files you read.

$(if [[ "${STAGGER:-0}" == 1 ]]; then
  echo "Phase 2, fan out in two steps. First launch ONLY the first lens below as one Agent call with subagent_type \"fork\" in the background. As soon as that call has been accepted, in your NEXT message launch the remaining $((n - 1)) lenses as Agent calls with subagent_type \"fork\", all in that one message. Give each fork this prompt, with its lens and id filled in:"
else
  echo "Phase 2, fan out. In ONE message, launch exactly $n Agent calls with subagent_type \"fork\", one per lens below. Give each fork this prompt, with its lens and id filled in:"
fi)

"Audit this repository for real bugs: behavior that is wrong for a user. Not style, not refactors. You already have the source in context from the recon; read more only if you need to. Your lens: <LENS>. Report only bugs you can point to in the code. Write ONLY JSON lines, one per finding, no prose, to .bench/<ID>.jsonl with the Write tool: {\"file\": \"src/...\", \"line\": <number>, \"title\": \"<short>\", \"why\": \"<what goes wrong, and when>\"}. At most 15 findings, strongest first. Your text output is not visible to anyone; only the file counts. Then stop."

Lenses:
EOF
  jq -r --arg s "$set" --argjson n "$n" '.[$s][:$n][] | "- id \(.id): \(.brief)"' "$here/lenses.json"
  cat << EOF

Phase 3. When all $n files exist in .bench/, reply with exactly: BENCH-DONE
EOF
} > "$prompt"

project_dir="$config_dir/projects"
# Interactive claude stops at the folder-trust prompt in a directory it has never
# opened; headless -p runs skip that check, so the fork arm must pre-trust.
if [[ -f "$cfg" ]]; then
  tmp=$(mktemp "$cfg.XXXXXX")
  jq --arg d "$(cd "$target" && pwd -P)" '.projects[$d].hasTrustDialogAccepted = true' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
fi
started=$(date +%s)
pane=$(cmux new-pane --workspace "$CMUX_WORKSPACE_ID" --direction down --focus false \
  --command "cd '$target'; CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 $CLAUDE_BIN --model $BENCH_MODEL --effort medium --settings '{\"disableAllHooks\":true}' --strict-mcp-config")
# "OK surface:N pane:N ..." or "OK <surface-uuid> <workspace-uuid>": the surface is token 2.
surface=$(awk '/^OK/ {print $2; exit}' <<< "$pane")
[[ -n "$surface" ]] || { echo "run-forks: could not parse a surface from: $pane" >&2; exit 1; }
screen() { cmux read-screen --surface "$surface" --workspace "$CMUX_WORKSPACE_ID" --lines 40 2> /dev/null; }
# Paste only once claude's input box is up; a paste sent earlier is lost.
for _ in $(seq 1 30); do screen | grep -q 'shift+tab to cycle' && break; sleep 2; done
for _ in 1 2 3; do
  cmux paste --surface "$surface" --workspace "$CMUX_WORKSPACE_ID" --submit - < "$prompt" > /dev/null || true
  sleep 8
  # A long paste shows collapsed as "[Pasted text #1 +N lines]", not its text.
  screen | grep -q -E 'Phase 1|Pasted text' && break
done
screen | grep -q -E 'Phase 1|Pasted text' || { echo "run-forks: prompt never reached the pane" >&2; exit 1; }
rm -f "$prompt"

deadline=$((started + 1200))
while [[ $(find "$target/.bench" -name '*.jsonl' | wc -l) -lt $n ]]; do
  [[ $(date +%s) -lt $deadline ]] || { echo "run-forks: timed out with $(ls "$target/.bench" | wc -l)/$n reports" >&2; break; }
  sleep 10
done
sleep 5
wall=$(($(date +%s) - started))
cp "$target"/.bench/*.jsonl "$out/" 2> /dev/null || true

# The session transcript: the newest session in this project that spawned subagents.
# Headless runs write transcripts to the same folder, so "newest .jsonl" is not enough.
slug=$(cd "$target" && pwd -P | sed 's|[^A-Za-z0-9]|-|g')
session=$(ls -td "$project_dir/$slug"/*/subagents 2> /dev/null | head -1)
transcript=${session:+$(dirname "$session").jsonl}
cmux close-surface --surface "$surface" --workspace "$CMUX_WORKSPACE_ID" --force > /dev/null || true
echo "wall=${wall}s transcript=$transcript" | tee "$out/usage.txt"
[[ -n "$transcript" ]] && ~/.cache/claude/venv/bin/python -I "$here/../scripts/usage.py" "$transcript" | tee -a "$out/usage.txt"
for f in "$out"/*.jsonl; do echo "$(basename "$f" .jsonl) findings=$(grep -c '^\s*{' "$f" || true)"; done
