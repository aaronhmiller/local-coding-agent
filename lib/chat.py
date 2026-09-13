# Chat REPL over the running mlx_lm.server. Invoked by bin/agent-chat.
#
# This lives in a file rather than a heredoc on purpose: `python - <<EOF` feeds
# the script in on stdin, which leaves input() with nothing to read, so the REPL
# exits instantly. Only an end-to-end test catches that.
#
# Standard library only.

import json
import sys
import urllib.error
import urllib.request

URL, MODEL, MAXTOK = sys.argv[1], sys.argv[2], int(sys.argv[3])
ONESHOT = sys.argv[4] if len(sys.argv) > 4 else ""

BOLD, DIM, RESET = "\033[1m", "\033[2m", "\033[0m"
messages = []


def stream(prompt):
    messages.append({"role": "user", "content": prompt})
    body = json.dumps(
        {"model": MODEL, "messages": messages, "stream": True, "max_tokens": MAXTOK}
    ).encode()
    req = urllib.request.Request(
        URL, data=body, headers={"Content-Type": "application/json"}
    )
    out = []
    try:
        with urllib.request.urlopen(req) as r:
            for raw in r:
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if data == "[DONE]":
                    break
                try:
                    delta = json.loads(data)["choices"][0].get("delta", {})
                except (json.JSONDecodeError, KeyError, IndexError):
                    continue
                # Some models stream reasoning separately. Dim it so the answer
                # stays visually distinct from the thinking.
                think = delta.get("reasoning_content")
                if think:
                    sys.stdout.write(DIM + think + RESET)
                    sys.stdout.flush()
                piece = delta.get("content")
                if piece:
                    out.append(piece)
                    sys.stdout.write(piece)
                    sys.stdout.flush()
    except urllib.error.URLError as e:
        print(f"\n[request failed: {e}]", file=sys.stderr)
        messages.pop()
        return
    except KeyboardInterrupt:
        # Drop the unanswered turn so the history stays coherent.
        print("\n[interrupted]", file=sys.stderr)
        messages.pop()
        return
    print()
    messages.append({"role": "assistant", "content": "".join(out)})


def main():
    if ONESHOT:
        stream(ONESHOT)
        return

    print(f"{BOLD}{MODEL}{RESET}  —  /reset  /system <text>  /tokens  /exit")
    print(
        f"{DIM}Plain chat. For file edits and commands, use agent-run opencode.{RESET}\n"
    )

    while True:
        try:
            line = input(f"{BOLD}you ›{RESET} ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return
        if not line:
            continue
        if line in ("/exit", "/quit"):
            return
        if line == "/reset":
            keep = [m for m in messages if m["role"] == "system"]
            messages.clear()
            messages.extend(keep)
            print(f"{DIM}conversation cleared{RESET}\n")
            continue
        if line.startswith("/system "):
            messages.insert(0, {"role": "system", "content": line[8:]})
            print(f"{DIM}system prompt set{RESET}\n")
            continue
        if line == "/tokens":
            # Rough, but enough to see context filling before it bites.
            chars = sum(len(m["content"]) for m in messages)
            print(f"{DIM}{len(messages)} messages, ~{chars // 4} tokens{RESET}\n")
            continue
        print(f"{BOLD}···{RESET} ", end="", flush=True)
        stream(line)
        print()


main()
