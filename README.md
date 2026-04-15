# cc-skills

A small, opinionated collection of [Claude Code](https://claude.com/claude-code) slash commands and skills I actually use.

Everything here is MIT-licensed. Grab what's useful; ignore the rest.

## Install

```bash
git clone git@github.com:STRML/cc-skills.git
```

Then symlink (or copy) what you want into your Claude Code config:

```bash
# User-level slash commands live here
ln -s "$(pwd)/cc-skills/commands/code-cleanup.md" ~/.claude/commands/code-cleanup.md
```

Slash commands become available immediately — no restart.

## Layout

```
commands/   Slash commands — invoke with /<name>
skills/     (future) Skills — invoke via the Skill tool
```

## Commands

### `/code-cleanup`

Deep codebase cleanup via eight parallel subagents. A single recon pass up front builds a shared context brief (languages, build commands, available tooling, landmines). Eight subagents then launch in one message, each owning one concern:

1. Deduplicate repeated logic (DRY where it cuts complexity)
2. Consolidate shared type definitions
3. Remove dead code (`knip`, `vulture`, `cargo machete`, etc.)
4. Break circular dependencies (`madge`, `pydeps`)
5. Replace weak types (`any`, `unknown`, `interface{}`) with real ones
6. Strip defensive programming that hides errors instead of handling them
7. Delete deprecated code, compat shims, and orphaned feature flags
8. Remove AI slop — narration comments, stubs, commented-out code

Each agent researches its full scope, writes a critical assessment with confidence levels, and applies only high-confidence fixes. Medium and low-confidence findings come back as a triage list.

The shared recon brief means all eight agent prompts share a long common prefix — the prompt cache absorbs most of it, so fan-out cost is much lower than running each agent cold.

## Contributing

PRs welcome. One skill or command per PR, please. Each addition should include a short rationale in the PR description — what problem it solves, what it doesn't try to do.

## License

MIT
