# Local coding agent in tmux

OpenCode and Pi driving a local model in tmux popups, on a 16GB MacBook, with
no network. Modeled on Viktor Gamov's
[When Claude Is Offline](https://gamov.io/posts/when-claude-is-offline/),
sized for a machine smaller than the one in the post.

This is the tool you fire up when you already know you're offline. There is no
cloud tier and no fallback logic — if you have a connection, close this and use
Claude Code.

## Default model

`gemma4:12b-it-qat` — 7.2GB, 256K native context (run at 32K here), native tool
calling.

QAT means quantization-aware training: Google trained it to be quantized rather
than compressing it afterwards, so it holds its output format together at 4-bit.
That matters more than raw coding score, because a malformed tool call doesn't
produce a worse edit, it produces no edit.

Why not something bigger? On 16GB your usable budget is about 10GB — macOS, a
browser and an editor take 4-5GB, and Metal's default wired limit sits near
10.6GB. Past that a model doesn't run slowly, it swaps, and an agent that swaps
is unusable.

| model | Q4 size | fits? |
|---|---|---|
| gemma4:12b-it-qat | 7.2GB | **yes** |
| gemma4:e4b | 9.6GB | yes, tight |
| GLM-4.7-Flash @ dynamic 2-bit | 10.5GB | yes, at quality cost |
| gpt-oss:20b | 14GB | swaps |
| qwen3-coder:30b | 19GB | no |
| glm-4.7-flash @ Q4_K_M | 19GB | no |

Activation sparsity is the trap: "30B-A3B, only 3B active" sounds small, but all
30B parameters still sit in memory. Sparsity buys speed, not footprint.

## The test that decides everything

Not size. Not benchmark scores. Whether the model returns real `tool_calls`.

An agent asks the model "which tool, with what arguments." If the model replies
with structured `tool_calls`, the runtime acts. If it describes the call in prose
— *"I'll now write the file with the following content…"* — the runtime gets text
and nothing happens. The model looks like it's working. No file appears.

```
$ agent-model test
Testing tool_calls support for: gemma4-12b-qat:ctx32k
{
  "content": "",
  "tool_calls": [ { "function": { "name": "write_file", ... } } ]
}
PASS — real tool_calls. This model can drive OpenCode and Pi.
```

Run it before trusting any new model. It matters most for heavily quantized
ones: low-bit quantization degrades structured output *before* it degrades
prose, so a model can chat fluently and still be useless in an agent loop.

## Install

Do this while you still have a connection.

```bash
git clone <this repo> ~/src/local-coding-agent
cd ~/src/local-coding-agent
./install.sh
```

It generates the agent configs, symlinks everything, pulls the active model and
runs the tool-call check. Then add the tmux fragment and put `~/.local/bin` on
your PATH — the installer prints both lines.

## Use

| key | what |
|---|---|
| `prefix + o` | OpenCode on the active model |
| `prefix + i` | Pi on the active model |
| `prefix + m` | model registry — what's installed, what's active |
| `prefix + T` | tool_call check |

Popups open in the current pane's directory and close back to where you were.

## Swapping models

`models/registry.json` is the single source of truth. Both agents' configs are
generated from it — edit the registry, never the generated files, or your next
sync silently discards the hand edit.

Adding any GGUF from Hugging Face is four commands:

```bash
agent-model add qwen-next --hf unsloth/Qwen3-Coder-GGUF:UD-Q4_K_XL --context 16384 --size 17
agent-model pull qwen-next     # downloads, then re-tags at your context size
agent-model test qwen-next     # the only gate that matters
agent-model use  qwen-next     # make it default, regenerate both configs
```

`--hf <repo>:<quant>` maps to Ollama's `hf.co/` prefix, so anything published as
GGUF works — pick the quant whose file size leaves you ~4GB of headroom, and
check real sizes in the repo's file listing rather than trusting a blog post.

Every registered model is written into both configs, not just the active one, so
you can also switch mid-session with `/model` inside either agent without
resyncing.

Other commands:

```bash
agent-model list               # names, sizes, which are actually pulled
agent-model show [name]        # everything the registry knows
agent-model remove <name>      # drop it (Ollama blobs untouched)
agent-sync --print             # preview generated configs, write nothing
agent-run opencode --model glm47-flash-q2   # one-off override
```

The runtime tag (`<name>:ctx32k`) is always derived from the registry's context
value, never stored, so changing context can't desync from the tag name.

## Context sizing

Ollama defaults every model to a 4096-token window, far too small for an agent
that reads files. `agent-model pull` re-tags with the real window, reusing the
same blobs, so it costs no extra disk.

32K is the default here rather than the 64K in the original post: a 7.2GB model
plus a 32K KV cache is already most of your headroom. Raise it once you've
watched Activity Monitor's swap stay flat through a real session. Registered
models can each carry their own value — the 2-bit GLM entry uses 16K precisely
because it spends more of the budget on weights.

## Web search, the one networked piece

`skills/tavily-search/` is a `SKILL.md` plus a `search.sh` that curls the Tavily
API. It exits in two seconds with a clear message when offline, and the SKILL.md
tells the model to say what it couldn't look up rather than guess.

It's here because skills are an open standard with overlapping discovery paths:
drop the folder in `~/.agents/skills/` and OpenCode, Pi, **and** Claude Code all
find it. One skill, three agents. That's also why the search tool is a script
rather than an MCP server — Pi doesn't support MCP by design, and a script works
everywhere.

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
models/registry.json      single source of truth: every model, the active one
lib/registry.sh           shared helpers (tag derivation, safe JSON writes)
bin/agent-model           list / show / add / pull / test / use / remove
bin/agent-sync            regenerates both agent configs from the registry
bin/agent-run             launches opencode|pi on the active model
bin/toolcall-check        the curl test that matters
config/opencode/          GENERATED — do not edit
config/pi/                GENERATED — do not edit
config/tmux/              popup bindings
skills/tavily-search/     SKILL.md + search.sh, shared by all three agents
install.sh                symlinks it all, pulls and verifies the model
```
