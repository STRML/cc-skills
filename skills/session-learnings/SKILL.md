---
name: session-learnings
description: End-of-session skill that captures lessons learned and updates project CLAUDE.md. Use before ending a session, before compacting context, or when explicitly asked to document learnings.
version: "1.0.0"
---

# Session Learnings

## Overview

Captures important discoveries, gotchas, and patterns from the current session and persists them to the project's CLAUDE.md file. Prevents repeating the same mistakes across sessions.

## When to Use

**Always trigger this skill when:**
- User says "update your claude.md" or "add that to claude.md"
- User says "before compacting..."
- User types `/clear` (via UserPromptSubmit hook - this IS a valid session-end trigger)
- PreCompact hook fires (context is about to be lost)
- Session is ending after significant work
- You discovered something important that should be remembered
- You made a mistake that should be avoided in future
- You learned project-specific conventions or patterns

**Valid hook triggers:**
- `PreCompact` - context about to be compacted
- `UserPromptSubmit` with `/clear` - user clearing session (treat as session end)
- Manual invocation via `/session-learnings`

Do NOT reject based on hook_event_name. If this skill is invoked, proceed with the workflow.

**Signs you should trigger this:**
- User corrected you on something project-specific
- You had to figure out a non-obvious workflow
- Build/test/deploy commands differ from defaults
- Project has unusual file structure or conventions

## What to Capture

### 1. Project-Specific Commands
```markdown
## Commands
- Build: `yarn build:prod` (not `yarn build`)
- Test specific file: `yarn test:match <pattern>`
- Dev server: port 3001 (not 3000)
```

### 2. Gotchas and Mistakes to Avoid
```markdown
## Gotchas
- Don't modify files in `dist/` - they're generated
- The `legacy/` folder uses old API - don't mix with new code
- Must run `yarn generate` after changing GraphQL schemas
```

### 3. Architecture Decisions
```markdown
## Architecture
- State management: Zustand (not Redux)
- Styling: Tailwind + CSS modules for component-specific
- API layer: tRPC, endpoints in `src/server/routers/`
```

### 4. User Preferences
```markdown
## Preferences
- Prefers functional components over class components
- Wants explicit types, not inferred
- Commit messages should reference issue numbers
```

### 5. File Locations
```markdown
## Key Files
- Main config: `config/app.config.ts`
- Environment: `.env.local` (not `.env`)
- Test fixtures: `__fixtures__/` (not `__mocks__/`)
```

## Workflow

### Step 1: Identify Learnings
Review the session for:
- Corrections user made
- Things that took multiple attempts
- Non-obvious discoveries
- Commands or patterns you had to figure out

### Step 2: Check Existing CLAUDE.md
```bash
# Check if project CLAUDE.md exists
cat .claude/CLAUDE.md 2>/dev/null || echo "No project CLAUDE.md"
```

### Step 3: Update or Create

**If CLAUDE.md exists:** Add new learnings to appropriate sections
**If no CLAUDE.md:** Create `.claude/CLAUDE.md` with learnings

### Step 4: Format Consistently

```markdown
# Project Name

## Commands
...

## Architecture
...

## Gotchas
...

## Conventions
...
```

## Examples

### Example 1: Build Command Discovery
**Session:** User corrected "use yarn, not npm"

**Add to CLAUDE.md:**
```markdown
## Commands
- This project uses yarn (yarn.lock present)
- Build: `yarn build`
- Test: `yarn test`
```

### Example 2: File Structure Gotcha
**Session:** Spent time looking for components in wrong place

**Add to CLAUDE.md:**
```markdown
## File Structure
- Components are in `src/components/` not `components/`
- Each component has its own folder with index.ts barrel export
- Styles are co-located as `Component.module.css`
```

### Example 3: API Pattern
**Session:** Learned the project's API conventions

**Add to CLAUDE.md:**
```markdown
## API Conventions
- All API routes in `src/pages/api/`
- Use `withAuth` wrapper for protected routes
- Response format: `{ data, error, meta }`
```

## Anti-Patterns

- **Generic advice:** Don't add things like "write clean code"
- **Obvious things:** Don't document standard conventions
- **Temporary info:** Don't add session-specific debugging notes
- **Duplicating docs:** Don't copy README content

**Do add:** Project-specific quirks, corrections, non-obvious patterns

## Checklist

Before session end or compact:

- [ ] Review corrections user made during session
- [ ] Note any non-obvious commands or workflows discovered
- [ ] Check for project conventions that differ from defaults
- [ ] Update `.claude/CLAUDE.md` with new learnings
- [ ] Keep entries concise and actionable
