#!/usr/bin/env bash
# Tavily web search for agents that cannot speak MCP.
# Usage: ./search.sh [--depth basic|advanced] [--max N] [--raw] "query"

set -euo pipefail

DEPTH="basic"
MAX=5
RAW=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --depth) DEPTH="$2"; shift 2 ;;
    --max)   MAX="$2";   shift 2 ;;
    --raw)   RAW=1;      shift   ;;
    --)      shift; break ;;
    -*)      echo "Unknown option: $1" >&2; exit 2 ;;
    *)       break ;;
  esac
done

QUERY="${*:-}"

if [[ -z "$QUERY" ]]; then
  echo "Usage: ./search.sh [--depth basic|advanced] [--max N] [--raw] \"query\"" >&2
  exit 2
fi

if [[ -z "${TAVILY_API_KEY:-}" ]]; then
  echo "TAVILY_API_KEY is not set. Export it in your shell profile, not in this repo." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required: brew install jq" >&2
  exit 1
fi

# Fail in two seconds rather than thirty when there is no connection — this
# setup is offline-first, so being offline is the expected case, not an error.
if ! curl -fsS --max-time 2 -o /dev/null https://api.tavily.com 2>/dev/null; then
  echo "OFFLINE — cannot reach the Tavily API. Work from the repository instead; do not guess." >&2
  exit 3
fi

RESPONSE=$(jq -n \
  --arg q "$QUERY" \
  --arg depth "$DEPTH" \
  --argjson max "$MAX" \
  '{query: $q, search_depth: $depth, max_results: $max, include_answer: true}' \
  | curl -sS --max-time 30 \
      -X POST "https://api.tavily.com/search" \
      -H "Authorization: Bearer ${TAVILY_API_KEY}" \
      -H "Content-Type: application/json" \
      -d @-)

if [[ "$RAW" == "1" ]]; then
  echo "$RESPONSE" | jq .
  exit 0
fi

if echo "$RESPONSE" | jq -e '.error? // empty' >/dev/null 2>&1; then
  echo "Tavily error: $(echo "$RESPONSE" | jq -r '.error')" >&2
  exit 1
fi

echo "$RESPONSE" | jq -r '
  (if (.answer // "") != "" then "ANSWER\n" + .answer + "\n" else "" end),
  "SOURCES",
  (.results[] | "- \(.title) — \(.url)")
'
