---
name: visual-css-refinement
description: Screenshot-driven CSS/UI debugging loop. Use when making visual changes (CSS, styling, layout) that need verification. Takes before/after screenshots, tracks changes, and iterates until the user is satisfied.
version: "1.0.0"
---

# Visual CSS Refinement

## Overview

A structured workflow for iterative CSS/UI changes with visual verification. Prevents "blind" CSS edits by requiring screenshot confirmation at each step.

## When to Use

**Always trigger this skill when:**
- Making CSS or styling changes
- Adjusting layout, spacing, padding, margins
- Fixing visual bugs ("the padding is wrong", "borders look bad")
- User says "screenshot it and look yourself"
- User says "better but..." (indicates iteration needed)
- Any UI change where visual verification matters

**Do NOT use for:**
- Pure logic/backend changes
- Changes where visual output doesn't matter
- Simple text content updates

## Workflow

### Phase 1: Baseline
1. **Take a "before" screenshot** using browser MCP or screenshot tool
2. **Document current state** - note what needs to change
3. **Create a checklist** of specific visual issues to fix

### Phase 2: Iterative Refinement Loop

```
┌─────────────────────────────────────────┐
│  1. Make CSS/style change               │
│  2. Take "after" screenshot             │
│  3. Compare to baseline/previous        │
│  4. Ask: "Does this match expectations?"│
│     ├─ YES → Continue to next issue     │
│     └─ NO  → Identify what's wrong      │
│              Loop back to step 1        │
└─────────────────────────────────────────┘
```

### Phase 3: Final Verification
1. Take final screenshot
2. Compare against original baseline
3. Confirm ALL issues from checklist are resolved
4. Only then proceed to commit

## Key Principles

### 1. Never Assume - Always Verify
```
❌ "I updated the padding, it should look better now"
✅ "I updated the padding. Let me take a screenshot to verify..."
   [takes screenshot]
   "The left padding is now 16px as expected, but I notice
   the bottom margin is still off. Fixing that next."
```

### 2. Track Changes Explicitly
Maintain a running list:
```markdown
## Changes Made
- [x] Fixed left padding (16px → 24px)
- [x] Removed orange border on table
- [ ] Fix alternate row backgrounds (in progress)
- [ ] Adjust mobile viewport padding
```

### 3. Acknowledge Partial Fixes
When user says "better but...":
```
✅ "You're right - the padding is fixed but the borders still
   need work. Taking another screenshot to examine the borders..."
```

### 4. Mobile/Responsive Checks
If changes affect layout, verify at multiple breakpoints:
- Desktop (1200px+)
- Tablet (768px)
- Mobile (375px)

## Common Patterns

### "Reduce it more"
User wants incremental adjustment. Make smaller change, screenshot, confirm.

### "You didn't fix X"
Missed something. Screenshot current state, identify the missed element, fix it.

### "It's worse now"
Revert last change, screenshot to confirm revert, try different approach.

### "The styles are weird compared to the rest"
Need to match existing design system. Screenshot surrounding elements for reference.

## Checklist Template

When starting CSS work, create this todo list:

```
- [ ] Take baseline screenshot
- [ ] List specific issues to fix
- [ ] Fix issue 1 + verify with screenshot
- [ ] Fix issue 2 + verify with screenshot
- [ ] ... (one per issue)
- [ ] Final full-page screenshot
- [ ] Compare against baseline
- [ ] Confirm with user before commit
```

## Anti-Patterns to Avoid

❌ **Blind editing**: Making multiple CSS changes without visual verification
❌ **Assuming fixes work**: "I fixed the padding" without screenshot proof
❌ **Batching changes**: Making 5 changes then taking 1 screenshot (can't isolate issues)
❌ **Ignoring mobile**: Only checking desktop when responsive matters
❌ **Premature commit**: Committing before user confirms visual changes are correct
