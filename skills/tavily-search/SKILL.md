---
name: tavily-search
description: Web search via the Tavily API. Use when the answer depends on current information that is not in the repository — release versions, changelogs, upstream docs, API signatures that may have changed. Requires TAVILY_API_KEY and a working network connection; it exits immediately with a clear message when offline, so it is safe to attempt. Do not use for questions answerable from the repository itself.
---

# Tavily Search

**This is the one tool here that needs a connection.** The rest of this setup is
built to work without one. If `search.sh` reports it is offline, do not retry
and do not guess the answer — say what you could not look up, and work from what
is in the repository.

Run a search and read the answer plus sources:

```bash
./search.sh "latest ollama release version"
```

Returns Tavily's synthesized answer followed by the top 5 results as
`title — url` lines.

## Options

```bash
./search.sh --depth advanced "glm 4.7 flash context window"   # slower, better
./search.sh --max 10 "opencode mcp configuration"             # more results
./search.sh --raw "tmux popup -E flag"                        # full JSON
```

## Reading the results

Prefer primary sources over content farms. A GitHub releases page, an official
docs site, or a project changelog beats a blog post that repeats a number.
When two sources disagree on a version or a figure, say so rather than picking
one — small local models are especially prone to reading a stale number off an
SEO page and reporting it confidently.

If the answer matters, follow the URL and read the page before you use the
number in code.
