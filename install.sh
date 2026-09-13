#!/usr/bin/env bash
# Symlink everything into place and warm the model cache.
# Idempotent — safe to re-run after a git pull.
#
#   ./install.sh            # link configs, skills, bin; download the model
#   ./install.sh --dry-run  # show what would happen
#   ./install.sh --no-pull  # skip the download
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

command -v jq >/dev/null 2>&1 || { echo "jq is required: brew install jq" >&2; exit 1; }

REPO_ROOT="$REPO"
# shellcheck source=lib/registry.sh
source "$REPO/lib/registry.sh"
PYTHON="$(agent_python)"

# Check that mlx-lm is importable, not that its console script is on PATH. The
# script lands in the bin/ of whichever Python installed it, which is often not
# on PATH; agent-serve falls back to `python -m mlx_lm.server` in that case.
if ! has_mlx_lm "$PYTHON"; then
  say "mlx-lm is not importable from $PYTHON."
  say ""
  say "On macOS this is usually PEP 668: Homebrew and system Python refuse"
  say "'pip install' with 'externally-managed-environment', so the install you"
  say "ran may have errored out. A venv is the normal fix."
  say ""
  if [[ $DRY == 1 ]]; then
    say "  would: $REPO/bin/agent-serve setup-python"
  elif [[ ! -t 0 ]]; then
    # No terminal — never block on a prompt nobody can answer.
    say "Not running interactively, so not prompting. Run this, then re-run:"
    say "    $REPO/bin/agent-serve setup-python"
    exit 1
  else
    printf 'Create a venv at ~/.venvs/mlx-agent and install mlx-lm now? [y/N] '
    read -r reply
    if [[ "$reply" =~ ^[Yy] ]]; then
      chmod +x "$REPO"/bin/*
      "$REPO/bin/agent-serve" setup-python || exit 1
      PYTHON="$(agent_python)"
    else
      say ""
      say "Do it yourself with either of:"
      say "    $REPO/bin/agent-serve setup-python"
      say "    $PYTHON -m pip install --break-system-packages mlx-lm"
      say ""
      say "Already installed elsewhere? Record that interpreter:"
      say "    $REPO/bin/agent-serve setup-python /path/to/existing/venv"
      say ""
      say "(Apple silicon only — mlx has no Intel Mac or Linux build.)"
      exit 1
    fi
  fi
elif ! command -v mlx_lm.server >/dev/null 2>&1; then
  say "note: mlx-lm imports fine but 'mlx_lm.server' is not on PATH."
  say "      agent-serve will use '$PYTHON -m mlx_lm.server'. Run 'agent-serve doctor'"
  say "      to see where the console script actually lives."
fi

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
  say "Downloading the active model into the Hugging Face cache"
  "$REPO/bin/agent-model" pull
  say ""
  say "Starting the server and checking it emits real tool_calls"
  "$REPO/bin/agent-serve" start

  # Keep the install-time check short. A first generation on a cold 16GB machine
  # can take minutes, and making people watch a five-minute hang at the end of
  # an installer is not a useful default — 120s is enough to tell "works" from
  # "something is wrong", and the full check is one command away.
  set +e
  AGENT_TIMEOUT=120 "$REPO/bin/toolcall-check"
  rc=$?
  set -e
  case $rc in
    0) ;;
    1) say ""
       say "  ^ the model answered but emitted no tool_calls, so it cannot drive"
       say "    an agent. Try another: agent-model add <name> --repo ..." ;;
    *) say ""
       say "  ^ no answer within 120s. That is not necessarily a model problem —"
       say "    a first generation on a cold machine is slow. Retry with more"
       say "    room once things settle:"
       say "        toolcall-check --timeout 900" ;;
  esac
fi

TMUX_LINE='source-file ~/.config/local-coding-agent/tmux/agent.tmux.conf'
TMUX_CONF="$HOME/.tmux.conf"

# Wire up tmux ourselves. Printing "add this line to ~/.tmux.conf" invites
# pasting a tmux command into the shell, where it is not a command at all.
say ""
say "tmux bindings"
if [[ $DRY == 1 ]]; then
  say "  would: append to $TMUX_CONF if absent"
elif grep -qF "local-coding-agent/tmux" "$TMUX_CONF" 2>/dev/null; then
  say "  already referenced in $TMUX_CONF"
else
  printf '\n# local coding agent popups\n%s\n' "$TMUX_LINE" >> "$TMUX_CONF"
  say "  appended to $TMUX_CONF"
fi

if [[ $DRY == 0 ]] && command -v tmux >/dev/null 2>&1 && tmux info >/dev/null 2>&1; then
  tmux source-file "$TMUX_CONF" 2>/dev/null \
    && say "  reloaded the running tmux server" \
    || say "  could not reload tmux; run inside tmux: tmux source-file ~/.tmux.conf"
fi

cat <<'EOF'

Done. One thing left, by hand:

  Make sure ~/.local/bin is on your PATH — add to ~/.zshrc:
       export PATH="$HOME/.local/bin:$PATH"

  (If tmux was not running just now, reload it later with this SHELL command:
       tmux source-file ~/.tmux.conf
   `source-file` on its own is a tmux command, not a shell one.)

Day to day:
       prefix + o     OpenCode        prefix + c   plain chat
       prefix + i     Pi              prefix + s   server status
       prefix + m     models          prefix + T   tool_call check

The server holds one model resident. Manage it with:
       agent-serve start | stop | restart | status | logs

Swapping in a model from Hugging Face (MLX format only, not GGUF):
       agent-model add <name> --repo mlx-community/<model>-4bit --size 7
       agent-model pull <name>
       agent-model use  <name>
       agent-serve restart
       agent-model test <name>
EOF
