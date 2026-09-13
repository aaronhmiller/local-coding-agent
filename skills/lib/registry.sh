#!/usr/bin/env bash
# Shared registry helpers. Sourced by bin/*, not run directly.

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REGISTRY="${AGENT_REGISTRY:-$REPO_ROOT/models/registry.json}"

die() { echo "error: $*" >&2; exit 1; }

need_jq() {
  command -v jq >/dev/null 2>&1 || die "jq is required: brew install jq"
}

need_registry() {
  need_jq
  [[ -f "$REGISTRY" ]] || die "no registry at $REGISTRY"
  jq -e . "$REGISTRY" >/dev/null 2>&1 || die "registry is not valid JSON: $REGISTRY"
}

# The Ollama tag this repo creates for a model: <name>:ctx<N>k
# Always derived, never stored, so context changes can't desync from the tag.
runtime_tag() {
  local name="$1"
  need_registry
  jq -er --arg n "$name" '
    .models[$n] // error("unknown model: \($n)")
    | "\($n):ctx\((.context // 32768) / 1024 | floor)k"
  ' "$REGISTRY"
}

model_field() {
  local name="$1" field="$2"
  need_registry
  jq -er --arg n "$name" --arg f "$field" '
    .models[$n] // error("unknown model: \($n)")
    | .[$f] // empty
  ' "$REGISTRY"
}

active_model() {
  need_registry
  jq -er '.active // error("no active model set")' "$REGISTRY"
}

model_exists() {
  need_registry
  jq -e --arg n "$1" '.models | has($n)' "$REGISTRY" >/dev/null 2>&1
}

ollama_up() {
  curl -fsS --max-time 2 -o /dev/null http://localhost:11434/api/tags 2>/dev/null
}

require_ollama() {
  ollama_up || die "Ollama is not running. Start it with: ollama serve"
}

# Write JSON to a file only if it parses, so a bad generator can never leave
# an agent with a broken config.
write_json() {
  local dest="$1" tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  jq -e . "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; die "refusing to write invalid JSON to $dest"; }
  mkdir -p "$(dirname "$dest")"
  mv "$tmp" "$dest"
}
