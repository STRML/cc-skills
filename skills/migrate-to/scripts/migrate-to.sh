#!/usr/bin/env bash
# Fork the current Claude Code session (repo + working files) onto another machine over cmux.
#
#   migrate-to.sh <host> [--name NAME] [REPO...]     run inside the session
#   migrate-to.sh list <host>                        show migrated sessions on the host
#   migrate-to.sh clean <host> <WINDOW|NAME|FORK-ID...|--all>
#
# `cmux session move` refuses a running session, so this copies the transcript under a new
# session id, cut just before the prompt that asked for the migration, and moves the copy.
# The fork resumes on the host as a window of one shared tmux session ("migrate") with
# Remote Control on, and a cmux pane opens next to this one attached to that window.
# The local session keeps running untouched.
#
# <host> is an ssh destination, or a short name from the aliases file
# (${XDG_CONFIG_HOME:-~/.config}/migrate-to/hosts, lines of "<name> <ssh-destination>").
set -euo pipefail

TMUX_SESSION=migrate
STATE="$HOME/.cache/migrate-to"
ALIASES="${XDG_CONFIG_HOME:-$HOME/.config}/migrate-to/hosts"
# Non-interactive ssh often gets a bare PATH; the host's tools usually live in one of these.
# Single-quoted so the host's shell expands $HOME.
# shellcheck disable=SC2016
RPATH='$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin'

die() { echo "migrate-to: $*" >&2; exit 1; }
log() { echo "[$(date +%H:%M:%S)] $*"; }

resolve_host() {
  local dest=""
  [[ -f "$ALIASES" ]] && dest=$(awk -v h="$1" '$1 == h { print $2; exit }' "$ALIASES")
  echo "${dest:-$1}"
}

# rsh never reads stdin, so it is safe inside `while read` loops; rsh_in forwards it.
# rx runs a command on the host with the tool PATH above.
rsh_in() { ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" "$@"; }
rsh() { rsh_in "$@" < /dev/null; }
rx() { rsh env "PATH=$RPATH" "$@"; }

trash_paths() {
  if command -v trash > /dev/null; then trash "$@" 2> /dev/null || true; else rm -rf -- "$@"; fi
}

# This machine's copy of a fork: transcript, its sidecar directory, file history.
trash_fork_local() {
  trash_paths "$HOME"/.claude/projects/*/"$1".jsonl "$HOME"/.claude/projects/*/"$1" \
    "$HOME/.claude/file-history/$1"
}

check_host() {
  local missing
  rsh true || die "cannot reach $HOST over ssh (BatchMode: keys or an agent must work without prompts)"
  missing=$(rx sh -c "'for t in bash claude tmux git rsync; do command -v \$t > /dev/null || echo \$t; done'")
  [[ -z "$missing" ]] || die "missing on $HOST: $(echo "$missing" | tr '\n' ' ')"
  for t in cmux jq rsync git uuidgen; do
    command -v "$t" > /dev/null || die "missing locally: $t"
  done
}

# Make sure the repo holding $1 exists on the host at the same path. A missing repo is
# copied as its .git directory and checked out, which is what `cmux session move` needs.
seed_repo() {
  local top common main
  top=$(git -C "$1" rev-parse --show-toplevel)
  common=$(cd "$top" && cd "$(git rev-parse --git-common-dir)" && pwd)
  main=$(dirname "$common")
  if rsh test -e "$main/.git"; then return 0; fi
  rsh test ! -e "$main" || die "$main exists on $HOST but is not a git repo"
  log "seeding $main on $HOST"
  rsh mkdir -p "$main"
  rsync -a "$common/" "$HOST:$main/.git/"
  rx git -C "$main" checkout -q -f HEAD
}

# Copy gitignored loose files (.env, local config). Ignored directories such as
# node_modules or build output are skipped: git lists them collapsed as "dir/".
copy_ignored_files() {
  local top list
  top=$(git -C "$1" rev-parse --show-toplevel)
  list=$(mktemp)
  git -C "$top" ls-files -o -i --exclude-standard --directory | grep -v '/$' > "$list" || true
  if [[ -s "$list" ]]; then
    log "copying $(wc -l < "$list" | tr -d ' ') ignored file(s) in $top"
    rsync -a --files-from="$list" "$top/" "$HOST:$top/"
  fi
  rm -f "$list"
}

# Repos the fork touched: the git toplevel of every cwd it ran in and every file it
# edited or wrote.
discover_repos() {
  local p d
  { jq -r 'select(.cwd) | .cwd' "$1"
    jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use")
      | .input.file_path // .input.notebook_path // empty' "$1"
  } | sort -u | while IFS= read -r p; do
    d=$p; [[ -d "$d" ]] || d=$(dirname "$p")
    [[ -d "$d" ]] && git -C "$d" rev-parse --show-toplevel 2> /dev/null || true
  done | sort -u
}

# True when the host has no copy of the repo yet or its copy has no uncommitted work.
host_repo_clean() {
  rsh test ! -e "$1/.git" || [[ -z "$(rx git -C "$1" status --porcelain)" ]]
}

# Mirror a repo that is not the session's cwd: git state, then working-tree changes.
# The caller checks host_repo_clean first, since uncommitted host work would be overwritten.
sync_repo() {
  local top common list f
  top=$(git -C "$1" rev-parse --show-toplevel)
  common=$(cd "$top" && cd "$(git rev-parse --git-common-dir)" && pwd)
  seed_repo "$top"
  log "syncing $top"
  # The host checkout is clean, so its tracked files are its whole non-ignored tree.
  # Any of them missing here was deleted here (or by a commit the host lacks).
  list=$(mktemp)
  rx git -C "$top" ls-files | while IFS= read -r f; do
    [[ -e "$top/$f" ]] || printf '%s\0' "$top/$f"
  done > "$list"
  if [[ "$common" == "$top/.git" ]]; then
    rsync -a "$common/" "$HOST:$common/"
  else
    rsync -a --exclude=/index --exclude=/HEAD "$common/" "$HOST:$common/"
    rsync -a "$top/.git" "$HOST:$top/"
  fi
  rx git -C "$top" checkout-index -a -f
  if [[ -s "$list" ]]; then rsh_in xargs -0 rm -f -- < "$list"; fi
  { git -C "$top" diff --name-only --diff-filter=d; git -C "$top" ls-files -o --exclude-standard; } > "$list"
  if [[ -s "$list" ]]; then rsync -a --files-from="$list" "$top/" "$HOST:$top/"; fi
  rm -f "$list"
  copy_ignored_files "$top"
}

# Write a copy of transcript $1 as session $3, ending before the last typed prompt (the
# /migrate-to request, whose turn is still running). Remote Control link records are
# dropped so the fork registers its own.
fork_transcript() {
  local src=$1 id=$2 fork=$3 dir cut
  dir=$(dirname "$src")
  cut=$(jq -n -r 'inputs | select(.type=="user" and (.isMeta | not))
      | select((.message.content | type) == "string"
               or ([.message.content[]? | .type] | index("tool_result") | not))
      | select(.message.content | tostring | startswith("<local-command") | not)
      | input_line_number' "$src" | tail -1)
  [[ -n "$cut" && "$cut" -gt 1 ]] || die "found no prompt to cut the fork at"
  head -n $((cut - 1)) "$src" | jq -c 'select(.type != "bridge-session")' \
    | sed "s/$id/$fork/g" > "$dir/$fork.jsonl"
  [[ -d "$dir/$id" ]] && cp -R "$dir/$id" "$dir/$fork"
  [[ -d "$HOME/.claude/file-history/$id" ]] \
    && cp -R "$HOME/.claude/file-history/$id" "$HOME/.claude/file-history/$fork"
  return 0
}

# Start the fork as a window of the shared tmux session on the host, install the attach
# script, and print the window index.
remote_launch() {
  local name=$1 dir=$2 id=$3
  rsh_in bash -s -- "$name" "$dir" "$id" "$TMUX_SESSION" << 'REMOTE'
set -euo pipefail
name=$1 dir=$2 id=$3 S=$4
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
claude=$(command -v claude)
TMUX=$(command -v tmux)
# Each pane attaches through its own grouped view of the shared session, so switching
# windows in one pane leaves the others alone. destroy-unattached is set after attach
# because tmux destroys a never-attached session as soon as the option is set.
mkdir -p "$HOME/.cache/migrate-to"
cat > "$HOME/.cache/migrate-to/attach.sh" << ATTACH
#!/bin/bash
exec $TMUX new-session -t "=$S" -s "$S-view-\$\$" \; select-window -t "\$1" \; set-option destroy-unattached on
ATTACH
# The folder is trusted locally (the session ran there), so skip the trust prompt that
# would otherwise hold Remote Control back until someone answers it in the pane.
cfg="$HOME/.claude.json"
if [[ -f "$cfg" ]] && command -v jq > /dev/null; then
  tmp=$(mktemp "$cfg.XXXXXX")
  jq --arg d "$dir" '.projects[$d].hasTrustDialogAccepted = true' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
fi
# `cmux session move` starts its own `claude --resume`; this one replaces it.
pkill -f "claude --resume $id" || true
sleep 1
cmd="$claude --resume $id --remote-control $name"
# Window ids (@N) are stable; indexes shift when the host has renumber-windows on.
if "$TMUX" has-session -t "=$S" 2> /dev/null; then
  wid=$("$TMUX" new-window -P -F '#{window_id}' -t "$S:" -n "$name" -c "$dir" "$cmd")
else
  wid=$("$TMUX" new-session -d -P -F '#{window_id}' -s "$S" -n "$name" -c "$dir" "$cmd")
fi
# Tag the window so `list` and `clean` can tell which fork it holds.
"$TMUX" set-option -w -t "$wid" @migrate_fork "$id"
echo "WID=$wid"
REMOTE
}

open_pane() {
  local wid=$1 name=$2 attach
  # exec, so the pane closes when ssh ends (detach, or `clean` killing the window).
  attach="exec env TERM=xterm-256color ssh -t $HOST bash .cache/migrate-to/attach.sh '$wid'"
  cmux new-pane --workspace "$CMUX_WORKSPACE_ID" --direction right --focus false --command "$attach" \
    || cmux new-workspace --name "$name" --focus false --command "$attach"
}

# Migrated windows on the host, one per line: window_id|index|name|fork|cwd.
remote_windows() {
  rx "tmux list-windows -t =$TMUX_SESSION -F '#{window_id}|#{window_index}|#{window_name}|#{@migrate_fork}|#{pane_current_path}'" \
    2> /dev/null || true
}

# The source session a fork came from, from the local history log.
fork_source() {
  [[ -n "$1" ]] || { echo "-"; return; }
  awk -v f="$1" '$4 == f { s = $2 } END { print (s ? s : "-") }' "$STATE/history.log" 2> /dev/null
}

cmd_list() {
  local wid idx name fork cwd
  printf '%-5s %-6s %-24s %-38s %-38s %s\n' ID INDEX NAME FORK SOURCE CWD
  while IFS='|' read -r wid idx name fork cwd; do
    printf '%-5s %-6s %-24s %-38s %-38s %s\n' "$wid" "$idx" "$name" "${fork:--}" "$(fork_source "$fork")" "$cwd"
  done < <(remote_windows)
  echo "views: $(rx "tmux ls -F '#{session_name}'" 2> /dev/null | grep -c "^$TMUX_SESSION-view-" || true)"
}

# Kill the matching windows (and their claude), drop this machine's stale copies of those
# forks, and kill unattached view sessions. The host keeps each fork's transcript, so
# `claude --resume <fork>` there still brings one back.
cmd_clean() {
  [[ $# -ge 1 ]] || die "usage: migrate-to.sh clean <host> <WINDOW|NAME|FORK-ID...|--all>"
  local wid idx name fork cwd t hit n=0
  while IFS='|' read -r wid idx name fork cwd; do
    hit=""
    for t in "$@"; do
      [[ "$t" == --all || "$t" == "$idx" || "$t" == "$name" || "$t" == "$wid" ]] && hit=1
      [[ -n "$fork" && ${#t} -ge 4 && "$fork" == "$t"* ]] && hit=1
    done
    [[ -n "$hit" ]] || continue
    # A pane's view would just move on to another window, so end the views showing this
    # one first; their ssh exits and cmux closes the panes.
    rx "tmux ls -F '#{session_name} #{window_id}'" 2> /dev/null \
      | awk -v p="^$TMUX_SESSION-view-" -v w="$wid" '$1 ~ p && $2 == w { print $1 }' \
      | while IFS= read -r t; do rx tmux kill-session -t "=$t"; done
    rx tmux kill-window -t "$wid"
    if [[ -n "$fork" ]]; then
      # "resum[e]" so the pattern does not match the shell running pkill itself.
      rx pkill -f "'claude --resum[e] $fork'" || true
      trash_fork_local "$fork"
    fi
    echo "CLEANED window $idx ($name) fork=${fork:--}"
    n=$((n + 1))
  done < <(remote_windows)
  rx "tmux ls -F '#{session_name} #{session_attached}'" 2> /dev/null \
    | awk -v p="^$TMUX_SESSION-view-" '$1 ~ p && $2 == 0 { print $1 }' \
    | while IFS= read -r t; do rx tmux kill-session -t "=$t"; echo "CLEANED view $t"; done
  [[ $n -gt 0 ]] || echo "no migrated window matched: $*"
}

cmd_migrate() {
  local name="" repos=()
  while (($#)); do
    case "$1" in
      --name) name=$2; shift 2 ;;
      *) repos+=("$(cd "$1" && pwd)"); shift ;;
    esac
  done
  local id=${CLAUDE_CODE_SESSION_ID:?not inside a Claude Code session}
  [[ -n "${CMUX_WORKSPACE_ID:-}" ]] || die "not running in a cmux workspace"
  local transcript cwd fork top=""
  transcript=$(find "$HOME/.claude/projects" -maxdepth 2 -name "$id.jsonl" | head -1)
  [[ -n "$transcript" ]] || die "no transcript for session $id"
  check_host
  # shellcheck disable=SC2016
  [[ ${#repos[@]} -eq 0 || "$(rsh 'echo $HOME')" == "$HOME" ]] \
    || die "home differs on $HOST; extra repos need the same absolute paths"

  fork=$(uuidgen | tr '[:upper:]' '[:lower:]')
  log "forking session $id as $fork"
  fork_transcript "$transcript" "$id" "$fork"
  # Until cmux has the fork, a failure leaves nothing behind.
  # shellcheck disable=SC2064
  trap "trash_fork_local '$fork'" EXIT
  # cmux moves and resumes in the fork's latest cwd, not the one the session started in.
  cwd=$(jq -r 'select(.cwd) | .cwd' "$(dirname "$transcript")/$fork.jsonl" | tail -1)
  [[ -n "$name" ]] || name=$(basename "$cwd" | tr -c 'A-Za-z0-9_.-' '-' | sed 's/-*$//')

  local code_flag=(--no-code)
  if top=$(git -C "$cwd" rev-parse --show-toplevel 2> /dev/null); then
    code_flag=()
    seed_repo "$cwd"
  else
    rsh mkdir -p "$cwd"
  fi

  local out ws
  log "cmux session move $fork --to $HOST ${code_flag[*]}"
  out=$(cmux session move "$fork" --to "$HOST" --name "$name" --no-focus "${code_flag[@]}")
  echo "$out"
  trap - EXIT
  # The move opens a `cmux ssh` workspace; tmux replaces it.
  ws=$(sed -n 's/^OK \(workspace:[0-9]*\).*/\1/p' <<< "$out")
  if [[ -n "$ws" ]]; then cmux close-workspace --workspace "$ws" > /dev/null || true; fi

  [[ ${#code_flag[@]} -eq 0 ]] && copy_ignored_files "$cwd"
  local r skipped=()
  while IFS= read -r r; do
    [[ -z "$r" || "$r" == "$top" ]] && continue
    if host_repo_clean "$r"; then sync_repo "$r"; else skipped+=("$r"); fi
  done < <({ for r in "${repos[@]}"; do git -C "$r" rev-parse --show-toplevel; done
             discover_repos "$(dirname "$transcript")/$fork.jsonl"; } | sort -u)
  for r in "${skipped[@]}"; do
    echo "SKIPPED $r: uncommitted changes on $HOST; commit or stash them there, then rerun"
  done

  local wid
  wid=$(remote_launch "$name" "$cwd" "$fork" | sed -n 's/^WID=//p')
  [[ -n "$wid" ]] || die "remote launch printed no window id"
  log "launched as window $wid of tmux session $TMUX_SESSION on $HOST"
  open_pane "$wid" "$name"
  cmux notify --title "Migrated to $HOST" \
    --body "$name is running in tmux '$TMUX_SESSION' with Remote Control on" > /dev/null || true
  mkdir -p "$STATE"
  echo "$(date -u +%FT%TZ) $id -> $fork $HOST $cwd" >> "$STATE/history.log"
  echo "MIGRATE-OK host=$HOST name=$name fork=$fork window=$wid"
}

main() {
  local usage="usage: migrate-to.sh <host> [--name NAME] [REPO...] | list <host> | clean <host> <target...>"
  [[ $# -ge 1 ]] || die "$usage"
  case "$1" in
    list | clean)
      [[ $# -ge 2 ]] || die "$usage"
      local sub=$1
      HOST=$(resolve_host "$2"); shift 2
      "cmd_$sub" "$@" ;;
    *)
      HOST=$(resolve_host "$1"); shift
      cmd_migrate "$@" ;;
  esac
}

main "$@"
