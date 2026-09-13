#!/usr/bin/env bash
# Shared helpers. Sourced by bin/*, not run directly.

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REGISTRY="${AGENT_REGISTRY:-$REPO_ROOT/models/registry.json}"
RUN_DIR="${AGENT_RUN_DIR:-$HOME/.local/state/local-coding-agent}"
PID_FILE="$RUN_DIR/mlx-server.pid"
LOG_FILE="$RUN_DIR/mlx-server.log"
MODEL_FILE="$RUN_DIR/mlx-server.model"
RUNTIME_FILE="$RUN_DIR/mlx-server.runtime"
RMLX_REGISTRY="$RUN_DIR/rmlx-models.json"

# Machine-local settings, deliberately OUTSIDE the repo.
#
# models/registry.json is version-controlled and ships with the project, so
# anything written into it is destroyed by the next `git pull` — which is
# exactly what happened to a recorded interpreter path once. Facts about THIS
# machine (which Python, which runtime is installed) live here instead; the
# repo file carries defaults only.
LOCAL_CONFIG="${AGENT_LOCAL_CONFIG:-$RUN_DIR/local.json}"

die() { echo "error: $*" >&2; exit 1; }

local_get() {
  [[ -f "$LOCAL_CONFIG" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  local v
  v="$(jq -er --arg k "$1" '.[$k] // empty' "$LOCAL_CONFIG" 2>/dev/null)" || return 1
  [[ -n "$v" ]] && echo "$v"
}

local_set() {
  local key="$1" value="$2" tmp
  mkdir -p "$(dirname "$LOCAL_CONFIG")"
  [[ -f "$LOCAL_CONFIG" ]] || echo '{}' > "$LOCAL_CONFIG"
  tmp="$(mktemp)"
  jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$LOCAL_CONFIG" > "$tmp" \
    && jq -e . "$tmp" >/dev/null \
    || { rm -f "$tmp"; die "could not write $LOCAL_CONFIG"; }
  mv "$tmp" "$LOCAL_CONFIG"
}

# Which Python runs mlx-lm and the download helpers.
#
# Precedence: AGENT_PYTHON env > local.json > registry server.python (legacy,
# still honoured so existing installs keep working) > python3.
#
# A recorded path matters because tmux popups do not reliably inherit your
# shell environment — a file works from anywhere, an exported variable does not.
agent_python() {
  if [[ -n "${AGENT_PYTHON:-}" ]]; then
    echo "$AGENT_PYTHON"
    return 0
  fi
  local p
  if p="$(local_get python)"; then
    echo "$p"
    return 0
  fi
  p=""
  if [[ -f "$REGISTRY" ]] && command -v jq >/dev/null 2>&1; then
    p="$(jq -r '.server.python // empty' "$REGISTRY" 2>/dev/null)"
  fi
  if [[ -n "$p" ]]; then
    # Self-healing migration: an interpreter still recorded in the old place
    # gets copied to local state, so the next repo update cannot lose it.
    local_set python "$p" 2>/dev/null || true
    echo "$p"
    return 0
  fi
  echo "python3"
}

has_mlx_lm() {
  "$1" -c 'import mlx_lm' >/dev/null 2>&1
}

mlx_lm_version() {
  "$1" -c 'import mlx_lm;print(getattr(mlx_lm,"__version__","?"))' 2>/dev/null || echo "?"
}

py_version() {
  "$1" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null || echo "?"
}

# Minimum Python for a current mlx-lm. This is not pedantry: pip silently
# resolves to whatever ancient mlx-lm still supports your interpreter, and an
# old mlx-lm fails later in confusing ways — missing CLI flags, and
# "Model type ... not supported" for architectures it predates.
PY_MIN_MAJOR=3
PY_MIN_MINOR=10

py_version_ok() {
  "$1" -c "import sys;sys.exit(0 if sys.version_info[:2] >= ($PY_MIN_MAJOR,$PY_MIN_MINOR) else 1)" 2>/dev/null
}

# Pick the newest sensible interpreter to build a venv from. macOS ships a 3.9
# with the Xcode Command Line Tools that is usually first on PATH as `python3`,
# which is exactly the trap above.
find_base_python() {
  local c
  for c in python3.14 python3.13 python3.12 python3.11 python3.10 \
           /opt/homebrew/bin/python3 /usr/local/bin/python3 python3; do
    if command -v "$c" >/dev/null 2>&1 && py_version_ok "$c"; then
      command -v "$c"
      return 0
    fi
  done
  return 1
}

need_jq() {
  command -v jq >/dev/null 2>&1 || die "jq is required: brew install jq"
}

need_registry() {
  need_jq
  [[ -f "$REGISTRY" ]] || die "no registry at $REGISTRY"
  jq -e . "$REGISTRY" >/dev/null 2>&1 || die "registry is not valid JSON: $REGISTRY"
}

active_model() {
  need_registry
  jq -er '.active // error("no active model set")' "$REGISTRY"
}

model_exists() {
  need_registry
  jq -e --arg n "$1" '.models | has($n)' "$REGISTRY" >/dev/null 2>&1
}

# With mlx-lm the served model id IS the Hugging Face repo id — there is no
# separate local tag to keep in sync, unlike Ollama's `ollama create` step.
model_repo() {
  need_registry
  jq -er --arg n "$1" '.models[$n].repo // error("unknown model: \($n)")' "$REGISTRY"
}

model_field() {
  need_registry
  jq -er --arg n "$1" --arg f "$2" '.models[$n] // error("unknown model: \($n)") | .[$f] // empty' "$REGISTRY"
}

server_host() { need_registry; jq -er '.server.host // "127.0.0.1"' "$REGISTRY"; }
server_port() { need_registry; jq -er '.server.port // 8080' "$REGISTRY"; }
server_url()  { echo "http://$(server_host):$(server_port)"; }

# Which inference server backs the endpoint: "rmlx" or "mlx-lm".
#
# Both speak OpenAI-compatible HTTP on the same port, so the generated agent
# configs are identical either way — the runtime is an implementation detail
# below the API. That is what makes switching cheap.
# Same precedence story as agent_python: whether rmlx is installed is a fact
# about this machine, so a local choice outranks the repo's default.
server_runtime() {
  local r
  if r="$(local_get runtime)"; then
    echo "$r"
    return 0
  fi
  need_registry
  jq -er '.server.runtime // "mlx-lm"' "$REGISTRY"
}

# Absolute path of a model's snapshot directory in the HF cache.
#
# mlx-lm takes an HF repo id and resolves this itself; rmlx takes a directory,
# so we have to resolve it. Same cache either way — no second download.
model_snapshot_path() {
  local py="$1" repo="$2"
  HF_HUB_OFFLINE=1 "$py" - "$repo" <<'PY' 2>/dev/null
import sys
try:
    from huggingface_hub import snapshot_download
    print(snapshot_download(repo_id=sys.argv[1], local_files_only=True))
except Exception:
    sys.exit(1)
PY
}

# rmlx --registry file: {"models":[{"id":"...","path":"/abs/path"}]}
#
# Using --registry rather than --model is deliberate: it lets us pin the served
# model id to the Hugging Face repo id, so the OpenCode and Pi configs are
# byte-identical across runtimes. With --model, rmlx picks its own short name
# and every config would have to change with the runtime.
write_rmlx_registry() {
  local dest="$1" id="$2" path="$3"
  jq -n --arg id "$id" --arg path "$path" \
    '{models: [{id: $id, path: $path}]}' | write_json "$dest"
}

server_running() {
  curl -fsS --max-time 2 -o /dev/null "$(server_url)/v1/models" 2>/dev/null
}

require_server() {
  server_running || die "the inference server is not running. Start it with: agent-serve start"
}

# The model the running server currently holds. Normally read from the file we
# wrote at launch; if that's missing — someone started mlx_lm.server by hand —
# fall back to asking the server, so status output is never blank when a server
# is plainly up.
running_model() {
  if [[ -f "$MODEL_FILE" ]]; then
    cat "$MODEL_FILE"
    return 0
  fi
  curl -fsS --max-time 2 "$(server_url)/v1/models" 2>/dev/null \
    | jq -er '.data[0].id // empty' 2>/dev/null \
    || echo ""
}

# Where huggingface_hub caches downloads. Used to tell "pulled" from "not pulled"
# without touching the network.
hf_cache_path() {
  local repo="$1"
  local base="${HF_HOME:-$HOME/.cache/huggingface}"
  echo "$base/hub/models--${repo//\//--}"
}

model_cached() {
  local dir
  dir="$(hf_cache_path "$1")"
  [[ -d "$dir" ]] && [[ -n "$(ls -A "$dir/snapshots" 2>/dev/null)" ]]
}

# Downloads go through the huggingface_hub *library*, not its CLI.
#
# The CLI is a console script, so it lands in the bin/ of whichever environment
# installed it — and with uv, pipx or a venv that bin/ is usually not on PATH.
# The library is always importable from the same interpreter that runs mlx-lm,
# which already depends on huggingface_hub. One less thing to install, one less
# PATH to get wrong.
has_hf_hub() {
  "$1" -c 'import huggingface_hub' >/dev/null 2>&1
}

hf_snapshot_download() {
  local py="$1" repo="$2"
  HF_HUB_OFFLINE=0 AGENT_DEBUG="${AGENT_DEBUG:-}" "$py" - "$repo" <<'PY'
import os, sys
from huggingface_hub import snapshot_download
try:
    print(snapshot_download(repo_id=sys.argv[1]))
except Exception as e:
    # A bare traceback here is 40 lines of httpx internals for what is almost
    # always "no network" or "wrong repo name". Say that instead; set
    # AGENT_DEBUG=1 when the one-liner isn't enough.
    if os.environ.get("AGENT_DEBUG"):
        raise
    name = type(e).__name__
    msg = str(e).strip().splitlines()[0] if str(e).strip() else "(no detail)"
    print(f"{name}: {msg}", file=sys.stderr)
    if "Proxy" in name or "Connect" in name or "Timeout" in name or "SSL" in name:
        print("Looks like a network problem — a download needs a real "
              "connection (a captive portal will do this too).", file=sys.stderr)
    elif "RepositoryNotFound" in name or "GatedRepo" in name or "401" in msg or "404" in msg:
        print("Check the repo name, and whether it is gated and needs "
              "`huggingface-cli login`.", file=sys.stderr)
    print("Re-run with AGENT_DEBUG=1 for the full traceback.", file=sys.stderr)
    sys.exit(1)
PY
}

# Can this mlx-lm actually load this model's architecture?
#
# mlx-lm is a TEXT-ONLY library. A repo whose config.json declares a multimodal
# model_type (gemma4_unified, say) has no module under mlx_lm.models, and the
# failure is horrible: the server starts, answers /v1/models, then throws inside
# a worker thread on the first real request and never replies. You get a silent
# five-minute timeout instead of an error. This turns that into one second.
#
# Prints "<model_type> <ok|unsupported|unknown>".
model_arch_check() {
  local py="$1" repo="$2"
  HF_HUB_OFFLINE=1 "$py" - "$repo" <<'PY' 2>/dev/null || echo "? unknown"
import json, os, sys, importlib
try:
    from huggingface_hub import snapshot_download
    path = snapshot_download(repo_id=sys.argv[1], local_files_only=True)
    with open(os.path.join(path, "config.json")) as f:
        mt = json.load(f).get("model_type", "?")
except Exception:
    print("? unknown"); sys.exit(0)
try:
    importlib.import_module(f"mlx_lm.models.{mt}")
    print(f"{mt} ok")
except ModuleNotFoundError:
    print(f"{mt} unsupported")
except Exception:
    print(f"{mt} unknown")
PY
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
