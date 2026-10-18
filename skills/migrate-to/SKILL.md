---
name: migrate-to
description: Fork the current Claude Code session, with its repo and every working file, onto another machine over ssh and keep going there. The fork resumes on the host inside one shared tmux session ("migrate") with Remote Control on, and a cmux pane opens beside this one attached to it. Also lists and cleans up the sessions it migrated. Use whenever the user types /migrate-to <host>, asks to move, hand off, or continue this session on another machine, or asks what is running there or to clean up migrated sessions.
argument-hint: <host> [--name NAME] [REPO...] | list <host> | clean <host> <target...>
---

# /migrate-to

`cmux session move` carries a Claude Code session between machines, but it refuses one that is running, and this skill runs inside the session it moves. So `scripts/migrate-to.sh` forks instead. It copies the transcript under a new session id, cut just before the prompt that asked for the migration, and moves the copy. This session keeps running untouched.

```
seed repo on host (if missing) ─▶ fork transcript (new id, cut before this prompt,
Remote Control link dropped) ─▶ cmux session move <fork> (HEAD, modified and untracked
files, transcript, memory, file history) ─▶ sync the other repos the session touched
─▶ copy gitignored loose files (.env)
─▶ close the `cmux ssh` workspace the move opens, kill its claude
─▶ host tmux "migrate": new window `claude --resume <fork> --remote-control <name>`
─▶ cmux pane beside this one (no focus change): ssh -t host → that window ─▶ notify
```

Requirements: cmux, jq, rsync, git, and uuidgen here; bash, claude (signed in to the same account, for Remote Control), tmux, git, and rsync on the host; ssh to the host without prompts (keys or an agent); the same home path on both machines, since repos land at their local absolute paths. The script checks all of them first and names anything missing. `jq` on the host is optional; without it the folder-trust prompt shows in the pane on a first visit.

## Hosts

`<host>` is any ssh destination: a `~/.ssh/config` alias, `user@host`, or a Tailscale name. Short names can map to destinations in `${XDG_CONFIG_HOME:-~/.config}/migrate-to/hosts`, one `<name> <ssh-destination>` per line (for example `devbox me@devbox.example.com`). Check that file before guessing what a short name means.

## Migrate

1. Work out which extra repos to pass. The script already carries the repo of the session's current cwd (where it last `cd`'d) through cmux, and it finds every repo the session ran in or changed with Edit/Write. Pass as `REPO` any repo it cannot see: one changed only through Bash (`sed -i`, a generator, `git -C`), and any repo the user names, whether or not this session touched it. Extra arguments are harmless. Each repo is mirrored to the same absolute path, and a worktree brings its main repo along.
2. Finish anything that should not straddle the move, such as an unsaved edit. The fork starts from the conversation as it stood before this prompt, so it knows nothing about the migration and never sees work done later in this turn.
3. Run the script as one Bash command. It needs ssh and the cmux socket, so in a sandboxed session run it outside the sandbox:
   `bash <skill-dir>/scripts/migrate-to.sh <host> [--name NAME] [REPO...]`
   The default name is the cwd's basename. It names the tmux window and the Remote Control session.
4. On `MIGRATE-OK`, tell the user in a few lines: it is running on the host under that name, in the new pane, in Remote Control, and as a window of the `migrate` tmux session. Add that this local session is still live and can be `/exit`ed when they are done here.
5. Report every `SKIPPED <repo>` line: that repo already has uncommitted work on the host, so it was left alone and the fork runs without it.
6. On a `migrate-to:` or cmux error, fix the cause and rerun. A cmux refusal about changes "that did not come from this session" means the host checkout holds work this session did not make, often an earlier migration's. Do not work around it, and do not write to the host by hand. Tell the user the path and stop.

## List and clean up

- `migrate-to.sh list <host>` prints one row per migrated window: tmux window id (`@N`, stable) and index, name, fork id, the source session it was forked from (from this machine's history log), and its cwd. It also counts the per-pane view sessions. Run it whenever the user asks what is running on a host or which session is which, and before any clean. Indexes can shift between calls (hosts with `renumber-windows on`), so target by id, name, or fork id.
- `migrate-to.sh clean <host> <target...>` kills each matching migrated window and its claude (windows opened by hand in `migrate` are never touched), and closes the cmux panes showing it. A target can be a window id, an index, a name, a fork-id prefix of at least 4 characters, or `--all`. It also drops this machine's stale copy of each fork, and kills any view session with no pane attached. The host keeps each fork's transcript, so `claude --resume <fork-id>` there still brings one back.
- Before cleaning, show the user the `list` rows that will go, unless they named the exact targets or said "all". Killing a window ends that agent mid-work.

## Notes

- Every migration adds one window to the single `migrate` tmux session on the host (`tmux attach -t migrate` there). Each pane attaches through its own grouped view (`migrate-view-<pid>`), which disappears when the pane closes, so panes don't steal each other's current window.
- The script marks the fork's directory trusted in the host's `~/.claude.json`, so the trust prompt never holds Remote Control back.
- `~/.cache/migrate-to/history.log` records each fork: source id, fork id, host, cwd.
