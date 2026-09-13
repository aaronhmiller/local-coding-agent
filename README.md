# Local coding agent in tmux

OpenCode and Pi driving a local model through **rMLX** (a single Rust binary,
no Python in the serving path), in tmux popups, on a 16GB MacBook, with no
network. mlx-lm remains a one-command fallback. Modeled on Viktor Gamov's
[When Claude Is Offline](https://gamov.io/posts/when-claude-is-offline/),
sized for a smaller machine and moved off Ollama onto Apple's own stack.

Fire this up when you already know you're offline. There's no cloud tier and no
fallback logic — if you have a connection, close this and use Claude Code.

## Why MLX, and why rMLX

MLX is Apple's framework, so it uses hardware that llama.cpp (and therefore
Ollama) doesn't touch. That matters for an agent: every tool-call round trip
re-prefills a growing conversation, so time-to-first-token dominates a coding
session far more than raw generation speed.

The default runtime here is **[rMLX](https://github.com/Pushkinist/rMLX)** — a
single Rust binary linking MLX's C ABI, with no Python in the serving path.

Be clear-eyed about what that buys. It is **not** mainly memory: the resident
process is model weights, and 4.5GB of Qwen3 is 4.5GB whatever language loads
it. Nor is it mainly speed: rMLX's own benchmarks put decode competitive with
mlx-lm and prefill at parity. What it buys is **operational**: one binary, no
venv, no PATH, no PEP 668, no pip silently resolving an ancient release against
an old interpreter. Every failure in this project's history was Python
packaging, and a single binary deletes that whole category.

The trade is maturity. rMLX is young and thinly staffed next to mlx-lm. So the
runtime is a **registry field**, not a rewrite:

```bash
agent-serve runtime            # which one is active
agent-serve runtime mlx-lm     # fall back
agent-serve restart
```

Both serve the same OpenAI-compatible API on the same port, so the generated
OpenCode and Pi configs are byte-identical across runtimes. Switching is a
restart, not a reconfiguration.

**Python doesn't disappear entirely, and it would be dishonest to imply it
does.** It's still used to download models (`huggingface_hub`) and to run
`agent-chat`. Neither is in the serving path — the resident process under rMLX
is pure Rust.

## Default model

`mlx-community/Qwen3-8B-4bit` — about 4.5GB of weights, `model_type: qwen3`,
text-only, trained for tool use. `qwen3-4b` (~2.4GB) is registered as a step
down if 8B is slow.

### Architecture support differs by runtime — and it will bite you

The single most important thing when picking a model: **mlx-lm can only load
architectures it implements as `mlx_lm/models/<model_type>.py`.** Multimodal
repos — vision, audio, anything named `*_unified`, `*-vl`, `*-vision` — are not
in there. Those need [mlx-vlm](https://github.com/Blaizzy/mlx-vlm), a different
library.

The failure mode is nasty, which is why this repo preflights it.
`mlx-community/gemma-4-12B-it-qat-4bit` looks perfect — right size, QAT, right
family — but its config.json declares `gemma4_unified`. mlx-lm has no such
module, so the server *starts fine*, answers `/v1/models`, and then throws
inside a worker thread on the first real request and never replies. What you see
is a five-minute timeout with no error.

So under the mlx-lm runtime, `agent-model pull` and `agent-serve start` read
`config.json` from the cache and check `mlx_lm.models.<model_type>` imports,
failing in about a second with the actual reason. That check is deliberately
**skipped under rMLX**, which has its own architecture coverage and serves
several multimodal families mlx-lm cannot — applying the mlx-lm test there would
reject models that actually work. To check a repo yourself before downloading it, open its
`config.json` on Hugging Face and compare `model_type` against:

```bash
ls "$(python3 -c 'import mlx_lm,os;print(os.path.dirname(mlx_lm.__file__))')/models"
```

### Sizing

On 16GB your usable budget is roughly 10GB — macOS, a browser and an editor take
4-5GB. MLX 4-bit conversions run a little larger than the equivalent GGUF
Q4_K_M, so check actual file sizes on the repo page rather than reasoning from
parameter counts. GLM-4.7-Flash is ~15GB as `mlx-community/GLM-4.7-Flash-4bit` —
out of reach here, and there's no MLX equivalent of Unsloth's dynamic 2-bit
GGUFs to rescue it.

## Memory, per runtime

### rMLX — `--max-ctx` is the control

`agent-serve` passes `--max-ctx` from the model's `context` (32768). **This is
not optional.** rMLX resolves it to `min(capacity, 4096)` when unset, and a 4k
window makes an agent useless the moment it reads two files. The KV ring starts
small and grows lazily toward the ceiling, so a large value costs nothing until
a prompt actually needs it — and prompts above it are rejected rather than
silently truncated. That rejection *is* the memory bound.

Do not expect KV quantization to save memory here. rMLX ships the widest KV
codec matrix of any MLX server, and its own docs are refreshingly blunt that
this is a fidelity/throughput feature, not a memory one: "no KV codec in the
tree currently holds fewer resident bytes than plain bf16." So the runtime runs
bf16 KV and bounds memory with `--max-ctx`. (I speculated the opposite before
reading the docs; the docs win.)

`--max-loaded-models 1` is passed explicitly too — rMLX can hold several models
resident, which on 16GB is not a feature you want by accident.

### mlx-lm — the kernel panic story

`mlx_lm.server` wires ~75% of RAM at startup. Wired memory can't be swapped, so
macOS can't reclaim it under pressure. Combined with a KV cache that grew
without bound, this produced **real kernel panics** — not crashed processes,
full forced reboots. [Issue #883](https://github.com/ml-explore/mlx-lm/issues/883)
is exactly this setup: mlx_lm.server plus OpenCode, context past ~58k tokens,
machine down.

[PR #906](https://github.com/ml-explore/mlx-lm/pull/906) fixed it by adding
`--prompt-cache-bytes` (2GB here, set in `registry.json` under
`server.promptCacheBytes`).

**Check whether your mlx-lm actually has that flag.** It merged in Feb 2026 but
the PyPI release lags the repo, so a current `pip install mlx-lm` may not
include it — mine didn't. `agent-serve` probes `--help` at startup and adapts:
if the flag is missing it omits it (passing an unknown flag makes argparse exit
before the server starts) and prints a loud warning. `agent-serve doctor` shows
the same thing under "server flags", and exits non-zero.

If the cap is missing, you have two options:

```bash
python -m pip install -U mlx-lm
python -m pip install 'mlx-lm @ git+https://github.com/ml-explore/mlx-lm'
```

Either way, treat the cap as a seatbelt rather than a guarantee. Related issues
are still open upstream — [#854](https://github.com/ml-explore/mlx-lm/issues/854)
(OOM kills the server instead of returning an HTTP error) and
[#1118](https://github.com/ml-explore/mlx-lm/pull/1118) (the flag may not be
honored in sequential serve mode). So regardless:

- keep context at 32K rather than pushing it up
- `agent-serve restart` between long sessions (`prefix + S`)
- if you're about to do something long and unattended, don't

This is the one place where Ollama was doing more for you than it looked.

## The test that decides everything

Not size. Not benchmark scores. Whether the model returns real `tool_calls`.

An agent asks the model "which tool, with what arguments." If the model replies
with structured `tool_calls`, the runtime acts. If it describes the call in prose
— *"I'll now write the file with the following content…"* — the runtime gets text
and nothing happens. The model looks like it's working. No file appears.

```
$ agent-model test
Testing tool_calls support for: mlx-community/Qwen3-8B-4bit
{
  "content": "",
  "tool_calls": [ { "function": { "name": "write_file", ... } } ]
}
PASS — real tool_calls. This model can drive OpenCode and Pi.
```

Run it before trusting any new model. It matters most for heavily quantized
ones: low-bit quantization degrades structured output *before* it degrades
prose, so a model can chat fluently and still be useless in an agent loop.

Three distinct outcomes, three different problems:

| exit | meaning | what to do |
|---|---|---|
| 0 | real `tool_calls` | you're good |
| 1 | answered, but narrated | different model or a higher-precision quant |
| 2 | no answer in time | a speed/memory problem, *not* a model problem |

Exit 2 is the one to read carefully. If an 8B model can't answer a trivial
prompt inside a few minutes, the machine is struggling — `mlx_lm.server` wires
~75% of RAM, and past that generation crawls instead of failing. Close the
browser, `agent-serve restart`, retry with `toolcall-check --timeout 900`. If
it's still slow, the model is too big for this machine and the honest fix is a
smaller one:

```bash
agent-model use qwen3-4b && agent-serve restart && agent-model test qwen3-4b
```

`qwen3-4b` is already in the registry for exactly this.

## Install

Apple silicon only — mlx has no Intel Mac or Linux build. Do this while you
still have a connection.

```bash
# rMLX runtime (default) — Apple silicon only, builds from source
brew install mlx-c
brew tap Pushkinist/rmlx
brew trust Pushkinist/rmlx     # third-party taps need explicit trust
brew install rmlx

git clone <this repo> ~/src/local-coding-agent
cd ~/src/local-coding-agent
./install.sh
```

rMLX links the system MLX through `mlx-c` rather than vendoring it, so
`brew install mlx-c` is a hard requirement. All install paths build from source
and need Rust 1.95+.

Prefer the Python runtime? `agent-serve runtime mlx-lm` before `./install.sh`,
and the venv flow below applies instead.

`install.sh` checks for mlx-lm and offers to build a venv if it's missing. Say
yes — on macOS that's almost always the right answer, because Homebrew and
system Python refuse `pip install` with `externally-managed-environment`
(PEP 668). The venv's interpreter is recorded in `registry.json` as
`server.python`, so tmux popups find it without you exporting anything.

```bash
agent-serve setup-python                          # ~/.venvs/mlx-agent
agent-serve setup-python --python /opt/homebrew/bin/python3.12
agent-serve setup-python --recreate               # rebuild on a newer Python
```

### Python 3.10 or newer, and this one bites

macOS ships **Python 3.9** with the Xcode Command Line Tools, and it's usually
first on PATH as `python3`. Build a venv on it and pip won't complain — it
quietly resolves whatever ancient mlx-lm still supports 3.9. You then discover
it much later, in two confusing ways: CLI flags that "don't exist"
(`--prompt-cache-bytes`), and models that fail to load with
`Model type ... not supported` even though the download was fine.

`setup-python` refuses interpreters below 3.10 and prefers the newest it can
find. `agent-serve doctor` flags an old one. If you're already stuck on a 3.9
venv:

```bash
brew install python@3.12
agent-serve setup-python --recreate
```

There's no `server` extra — `pip install mlx-lm` is the whole install.

It generates the agent configs, symlinks everything, downloads the model into
the Hugging Face cache, starts the server and runs the tool-call check. Then add
the tmux fragment and put `~/.local/bin` on your PATH — the installer prints
both lines.

## Use

### There is no web page at localhost:8080

`mlx_lm.server` is an API, not a website. It serves `/v1/models` and
`/v1/chat/completions` and nothing else, so opening `http://127.0.0.1:8080` in a
browser correctly returns 404. There is no ChatGPT-style UI to find.

Three ways to actually talk to it:

```bash
agent-chat                    # plain chat REPL      (prefix + c)
agent-chat "quick question"   # one-off, prints and exits
agent-run opencode            # the real thing: reads and edits files
```

`agent-chat` talks to the **already-running** model over the API, so it costs no
extra memory. Avoid `mlx_lm.chat` — it loads a second copy of the weights, which
on 16GB is how you start swapping. If you want a browser UI, point Open WebUI or
LM Studio at `http://127.0.0.1:8080/v1`; it's just an OpenAI-compatible endpoint.

| key | what |
|---|---|
| `prefix + o` | OpenCode on the active model |
| `prefix + i` | Pi on the active model |
| `prefix + c` | plain chat (no file access) |
| `prefix + m` | model registry |
| `prefix + s` | server status |
| `prefix + S` | restart the server |
| `prefix + T` | tool_call check |

`agent-run` and `toolcall-check` both start the server if it isn't up, so the
popups work from cold.

```bash
agent-serve start | stop | restart | status | logs [-f] | doctor
```

## When something won't start

`agent-serve doctor` is the first thing to run. It checks the interpreter,
whether `mlx_lm` imports, where the console script actually lives, the HF cache,
whether the active model is downloaded, and what's holding the port.

The most common failure is `command -v mlx_lm.server` coming back empty. That
usually does **not** mean mlx-lm is missing. pip installs the console script
into the `bin/` of whichever Python did the install — a venv, a `--user`
directory, Homebrew's Python — and if that directory isn't on your PATH the
command disappears while the package imports fine. It bites harder under tmux,
which may not inherit the shell environment you installed from.

`agent-serve` handles this by falling back to `python3 -m mlx_lm.server`, so it
works either way. To fix it properly, `doctor` prints the directory to add to
your PATH.

If `import mlx_lm` genuinely fails, it's an install problem, not a PATH problem
— run `agent-serve setup-python`. Two failure modes worth naming:

- **`externally-managed-environment`** on `pip install`: PEP 668. Use the venv.
- **`ModuleNotFoundError: No module named 'mlx'`** *after* mlx-lm installs
  successfully: mlx-lm installs on any platform, but its `mlx` dependency is
  gated to Darwin. This machine isn't Apple silicon, and nothing here will work
  on it — use the Ollama approach instead.

Interpreter precedence is `AGENT_PYTHON` env → `server.python` in the registry →
`python3`. `agent-serve doctor` prints which one it picked.

## Two config files, and why

| file | in git? | holds |
|---|---|---|
| `models/registry.json` | yes | models, context sizes, defaults — the shared setup |
| `~/.local/state/local-coding-agent/local.json` | no | which Python, which runtime — facts about *this* machine |

The split exists because it was got wrong once. The interpreter path was
originally recorded in `models/registry.json`, so the next repo update
overwrote it, and everything failed with an unhelpful "mlx-lm is not installed
for python3" — pointing at bare `python3` rather than the venv that was working
five minutes earlier.

Anything `agent-serve setup-python` or `agent-serve runtime` records now goes to
local state, which repo updates never touch. An interpreter still recorded the
old way is migrated automatically the first time it's read. `agent-serve doctor`
prints the local file and says which source each setting came from.

## Swapping models

`models/registry.json` is the single source of truth. Both agents' configs are
generated from it — edit the registry, never the generated files, or your next
sync silently discards the hand edit.

```bash
agent-model add glm-flash --repo mlx-community/GLM-4.7-Flash-4bit --size 15
agent-model pull glm-flash      # into the HF cache; needs a connection
agent-model use  glm-flash      # default + regenerate configs
agent-serve restart             # actually load it
agent-model test glm-flash      # the gate that matters
```

**MLX format only.** mlx-lm cannot read GGUF, so a repo full of `.gguf` files is
useless here — `agent-model add` warns if the name looks like one. Look under
`mlx-community/` or `lmstudio-community/` for `-4bit` / `-8bit` / `-MLX`
conversions of the model you want.

Other commands:

```bash
agent-model list            # names, repos, sizes, what's downloaded and serving
agent-model show [name]     # everything the registry knows, plus cache path
agent-model remove <name>   # drop it (cached weights untouched)
agent-sync --print          # preview generated configs, write nothing
```

**Only the active model is emitted into the agent configs.** That's deliberate,
and a change from the Ollama version. mlx-lm will load a different model if a
request names one, but on 16GB that means a second set of weights arriving while
the first is still resident. Offering the agent a menu it can hurt you with is a
bad trade, so switching goes through `use` + `restart`.

## Offline behavior

`agent-serve` exports `HF_HUB_OFFLINE=1`, which stops huggingface_hub from
stalling on a revision check when there's no network. Models must already be in
the cache; `agent-model pull` is the only command that needs a connection, and
`agent-model list` shows you what's downloaded before you're depending on it.

Downloads go through the **huggingface_hub library**, not its CLI. That's
deliberate: the CLI is a console script, so with uv, pipx or a venv it lands in
a `bin/` that usually isn't on your PATH, and you get "need the Hugging Face
CLI" while the package is sitting right there. The library is importable from
the same interpreter that runs mlx-lm, which already depends on it — so there's
nothing extra to install and no second PATH to get wrong.

Download errors print one line rather than a wall of httpx traceback. Set
`AGENT_DEBUG=1` when you need the full thing.

## Web search, the one networked piece

`skills/tavily-search/` is a `SKILL.md` plus a `search.sh` that curls the Tavily
API. It exits in two seconds with a clear message when offline, and the SKILL.md
tells the model to say what it couldn't look up rather than guess.

It's here because skills are an open standard with overlapping discovery paths:
drop the folder in `~/.agents/skills/` and OpenCode, Pi, **and** Claude Code all
find it. One skill, three agents. That's also why it's a script rather than an
MCP server — Pi doesn't support MCP by design, and a script works everywhere.

The SKILL.md spends a paragraph on how to read results. That's deliberate: the
original post's local agent found two SEO blogs, read a version number off one,
and reported it confidently and wrongly. Small models are good at coding and bad
at judging sources, and they don't know the difference.

## What this is not

It's not Claude Code. It makes more mistakes, it's slower, and its tool-call
formatting occasionally slips back into prose if you phrase a request as "run
this exact command" instead of "find me X." Expect to supervise it.

It exists so that no connection costs you quality instead of costing you the
ability to work at all.

## Layout

```
models/registry.json      single source of truth: models, active one, server config
lib/registry.sh           shared helpers (repo lookup, HF cache, runtime dispatch)
lib/chat.py               the agent-chat REPL (stdlib only)
bin/agent-serve           lifecycle for the inference server (rmlx or mlx-lm)
bin/agent-chat            plain chat REPL against the running model
bin/agent-model           list / show / add / pull / test / use / remove
bin/agent-sync            regenerates both agent configs from the registry
bin/agent-run             launches opencode|pi, starting the server if needed
bin/toolcall-check        the curl test that matters
config/opencode/          GENERATED — do not edit
config/pi/                GENERATED — do not edit
config/tmux/              popup bindings
skills/tavily-search/     SKILL.md + search.sh, shared by all three agents
install.sh                symlinks it all, downloads and verifies the model
```

## Verify against your own install

`mlx_lm.server`'s flags move between releases, and the PyPI release lags the
repo. Rather than assume, `agent-serve` reads `--help` at startup and passes
only what your binary accepts — an unknown flag makes argparse exit before the
server ever starts, which looks like a crash with no explanation.

`agent-serve doctor` reports what it found. Extra flags go in `registry.json`
under `server.extraArgs` rather than into the script.

Two invocation notes: `python -m mlx_lm.server` is deprecated upstream, so the
PATH fallback uses `python -m mlx_lm server`. And `--max-kv-size` exists for
`mlx_lm.generate` but still isn't wired into the server.
