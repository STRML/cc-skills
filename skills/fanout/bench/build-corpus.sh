#!/usr/bin/env bash
# Build a seeded-defect corpus: revert historical bug-fix commits onto a pinned
# commit, then export the result as a fresh single-commit repo so `git log` cannot
# leak the answers. The answer key (one entry per reintroduced bug) stays outside.
#
#   build-corpus.sh <source-repo> <pinned-sha> <out-dir> <target-count> <candidate-sha...>
#
# Candidates are tried in order; a revert that does not apply cleanly is skipped.
# Out: <out-dir>/target (the repo agents audit) and <out-dir>/answer-key.json.
set -euo pipefail

src=$1 pin=$2 out=$3 want=$4; shift 4
[[ ! -e "$out" ]] || { echo "build-corpus: $out exists" >&2; exit 1; }
mkdir -p "$out"
work="$out/.work"
git clone -q --no-hardlinks "$src" "$work"
git -C "$work" checkout -q -b seeded "$pin"

key="$out/answer-key.json"
echo "[" > "$key"
kept=0
for sha in "$@"; do
  [[ $kept -lt $want ]] || break
  if ! git -C "$work" revert --no-edit "$sha" > /dev/null 2>&1; then
    git -C "$work" revert --abort 2> /dev/null || true
    echo "skip $sha (does not revert cleanly)" >&2
    continue
  fi
  kept=$((kept + 1))
  subject=$(git -C "$work" log -1 --format=%s "$sha")
  files=$(git -C "$work" show --format= --name-only HEAD -- src/ | jq -R . | jq -s -c .)
  hunks=$(git -C "$work" show --format= -U0 HEAD -- src/ | grep -E '^(\+\+\+|@@)' | jq -R . | jq -s -c .)
  [[ $kept -gt 1 ]] && echo "," >> "$key"
  jq -n --arg id "D$kept" --arg sha "$sha" --arg subject "$subject" \
    --argjson files "$files" --argjson hunks "$hunks" \
    '{id: $id, fix_sha: $sha, fix_subject: $subject, files: $files, hunks: $hunks}' >> "$key"
  echo "kept $sha: $subject" >&2
done
echo "]" >> "$key"
jq . "$key" > "$key.tmp" && mv "$key.tmp" "$key"

# Fresh repo, one commit, no history.
mkdir "$out/target"
git -C "$work" archive HEAD | tar -x -C "$out/target"
git -C "$out/target" init -q
git -C "$out/target" add -A
git -C "$out/target" -c user.email=bench@local -c user.name=bench commit -q -m "snapshot"
# Dependencies, so agents can typecheck and run tests. APFS clone where available.
if [[ -d "$src/node_modules" ]]; then
  cp -cR "$src/node_modules" "$out/target/" 2> /dev/null || cp -R "$src/node_modules" "$out/target/"
fi
rm -rf "$work"
echo "corpus: $kept defects in $out/target, key $key" >&2
