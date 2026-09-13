#!/usr/bin/env bash
# Symlink everything into place. Idempotent — safe to re-run after a git pull.
#
#   ./install.sh            # link configs, skills, bin; pull the active model
#   ./install.sh --dry-run  # show what would happen
#   ./install.sh --no-pull  # skip the model download
#
# Run this while you still have a connection. The whole point is that nothing
# afterwards needs one.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY=0
PULL=1
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --no-pull) PULL=0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '%s\n' "$*"; }
run() { if [[ $DRY == 1 ]]; then say "  would: $*"; else "$@"; fi; }

link() {
  local src="$1" dst="$2"
  run mkdir -p "$(dirname "$dst")"
  if [[ -e "$dst" && ! -L "$dst" ]]; then
    say "  backing up existing $dst -> $dst.bak"
    run mv "$dst" "$dst.bak"
  fi
  say "  $dst -> $src"
  run ln -sfn "$src" "$dst"
}

command -v jq >/dev/null 2>&1 || { echo "jq is required: brew install jq" >&2; exit 1; }

say "Generating agent configs from models/registry.json"
if [[ $DRY == 1 ]]; then
  say "  would: agent-sync"
else
  chmod +x "$REPO"/bin/*
  "$REPO/bin/agent-sync"
fi

say "OpenCode config"
link "$REPO/config/opencode/opencode.json" "$HOME/.config/opencode/opencode.json"

say "Pi models"
link "$REPO/config/pi/models.json" "$HOME/.pi/agent/models.json"

say "Shared skills (OpenCode + Pi + Claude Code all read this path)"
link "$REPO/skills/tavily-search" "$HOME/.agents/skills/tavily-search"

say "tmux config fragment"
link "$REPO/config/tmux" "$HOME/.config/local-coding-agent/tmux"

say "Scripts on PATH"
for f in "$REPO"/bin/*; do
  run chmod +x "$f"
  link "$f" "$HOME/.local/bin/$(basename "$f")"
done
run chmod +x "$REPO/skills/tavily-search/search.sh"

if [[ $PULL == 1 && $DRY == 0 ]]; then
  say ""
  say "Pulling the active model (needs a connection — do this before you fly)"
  "$REPO/bin/agent-model" pull
  say ""
  say "Verifying it emits real tool_calls"
  "$REPO/bin/agent-model" test || say "  ^ that model cannot drive an agent. Pick another: agent-model list"
fi

cat <<'EOF'

Done. Two things left, by hand:

  1. Add to ~/.tmux.conf:
       source-file ~/.config/local-coding-agent/tmux/agent.tmux.conf
     then: tmux source-file ~/.tmux.conf

  2. Make sure ~/.local/bin is on your PATH:
       export PATH="$HOME/.local/bin:$PATH"

Day to day:
       prefix + o     OpenCode        prefix + m   model list
       prefix + i     Pi              prefix + T   tool_call check

Swapping in a model from Hugging Face:
       agent-model add <name> --hf <repo>:<quant> --context 16384
       agent-model pull <name>
       agent-model test <name>
       agent-model use  <name>
EOF
