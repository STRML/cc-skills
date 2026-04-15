---
name: recall
description: Use when searching past Claude Code session history to recall previous work, decisions, context, files touched, or anything discussed in earlier conversations — supports date-based filtering, project filtering, and deep content search via search-sessions
---

# recall — Session Memory Search

## Overview

Searches Claude Code session history using `search-sessions` (https://github.com/sinzin91/search-sessions). Two modes: index search (instant, searches metadata) and deep search (searches full message content).

## When to Use

- "What did we work on yesterday?"
- "Did I ever fix that auth redirect bug?"
- "Which sessions touched settings.json?"
- "Show me recent sessions for the rush auto works project"
- Any time you need to recall past conversation context

## Usage

```
/recall <query>              Index search (instant, searches metadata)
/recall --deep <query>       Deep search (searches full message content)
/recall today                Sessions from today
/recall yesterday            Sessions from yesterday
/recall last week            Sessions from the past week
/recall <query> --project X  Filter to a specific project
```

## Commands

### Index search (default — instant, searches metadata)

```bash
search-sessions "query terms"
```

### Deep search (searches full message content, slower)

```bash
search-sessions "query terms" --deep
```

### Filter by project

```bash
search-sessions "query" --project myapp
```

### Filter by date

```bash
search-sessions "query" --since "3 days ago"
search-sessions "query" --since 2026-02-01 --until 2026-02-15
search-sessions "query" --date today
search-sessions "query" --since "last week"
```

### Temporal browsing (no query needed)

```bash
search-sessions --date today
search-sessions --since yesterday
search-sessions --since "last week"
search-sessions --since "last month"
```

### Increase result limit

```bash
search-sessions "query" --limit 50
```

## Presenting Results

Format results as:

```
1. 2026-03-03 14:22 — project-name
   Summary or matched context

2. 2026-03-03 09:15 — project-name
   Summary or matched context
```

## No results

- Temporal: "No sessions found for [date range]."
- Topic: "No sessions matched '[query]'. Try `/recall --date today` to browse by date, or `--deep` for full content search."
