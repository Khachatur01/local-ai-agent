# local-ai-agent

Nix flake that runs [Claude Code](https://docs.anthropic.com/en/docs/claude-code/overview) against a locally served Ollama model, so agentic development works with no API calls leaving the machine.

## Quick start

```sh
nix run .#setup      # once: pulls ~22 GB and builds the derived models
nix run .#doctor     # check context, eviction and cache settings
nix run .            # start Claude Code on the local model
```

Or from a dev shell:

```sh
nix develop
agent                # works from any git repo; starts at its root
```

`agent` is usable from any project, not just this one:

```sh
cd ~/some/other/repo
nix run github:Khachatur01/local-ai-agent
```

## Commands

| Command | What it does |
|---|---|
| `nix run .#setup` | Pulls base models and builds the derived ones. Run once; idempotent. |
| `nix run .#doctor` | Checks every known failure mode and names the fix for each. Non-zero exit on failure. |
| `nix run .#bench` | Measures cold prefill, cached prefill and generation tok/s. |
| `nix run .` | Starts Claude Code. Verifies only — never pulls or rebuilds. |

## Server settings

Nothing to do: `agent` starts its own ollama when nothing is listening on
11434, and passes these on explicitly, because a server inherits none of them
by itself. They come from `serverEnv` in `nix/settings.nix`.

| Variable | Value | Why |
|---|---|---|
| `OLLAMA_KEEP_ALIVE` | `24h` | The 5 minute default evicts the model between turns and discards the KV cache: a ~3 minute stall instead of ~4 seconds. |
| `OLLAMA_MAX_LOADED_MODELS` | `2` | Unset is not the same as fine — Ollama then evicts `qwen3-fast` to fit the 35 B, and the side calls land on the 35 B. |
| `OLLAMA_KV_CACHE_TYPE` | `q8_0` | Roughly halves KV, which is what makes the two contexts affordable. |
| `OLLAMA_FLASH_ATTENTION` | `1` | Prerequisite for the above. |
| `OLLAMA_NUM_PARALLEL` | `1` | Each slot allocates its own KV cache, so more slots multiply the ~23 GB footprint. |

A server `agent` starts runs as you and so uses `~/.ollama/models`. It stays
up after the agent exits, and the next run reuses it.

`local-ai-doctor` reads the running server's environment either way — from
the systemd unit when there is one, from `/proc` otherwise — so a server you
manage yourself gets checked against the same table.

### Optional: run it under systemd instead

On NixOS you can have the service managed declaratively. This is a
convenience, not a requirement — the flake works on any machine without it.

```nix
{
  imports = [ inputs.local-ai-agent.nixosModules.default ];

  services.local-ai-agent = {
    enable = true;
    ollamaPackage = pkgs.ollama-cuda; # the CPU default offloads nothing
  };
}
```

| Option | Default | Description |
|---|---|---|
| `services.local-ai-agent.enable` | `false` | Serve ollama with the settings above. |
| `services.local-ai-agent.ollamaPackage` | `pkgs.ollama` | Which ollama build to serve; `pkgs.ollama-cuda` on an NVIDIA box. |
| `services.local-ai-agent.keepAlive` | `"24h"` | `OLLAMA_KEEP_ALIVE`. Use `"-1"` to never unload. |
| `services.local-ai-agent.kvCacheType` | `"q8_0"` | KV quantization; roughly halves KV memory. |
| `services.local-ai-agent.maxLoadedModels` | `2` | Must be ≥ 2 so both models stay resident. |
| `services.local-ai-agent.installAgent` | `true` | Install the four commands system-wide. |

It enables `services.ollama` for you, and anything you set on
`services.ollama` yourself still wins. The service keeps its models in
`/var/lib/ollama/models`, which is a *different store* from the one a
user-started server reads — pick one and stay with it, or `setup` will pull
the 22 GB twice.

## Performance

Measured on an RTX 3060 Laptop (6 GB VRAM, 30 GB RAM). The 35B Q4_K_M model is
~22 GB, so only 34 of 42 layers offload and it runs ~89 % on CPU.

| What | Measured |
|---|---|
| Cold prefill, 27 k prompt | 176.6 s (155 tok/s) |
| Cached prefill, same prompt | 5.1 s |
| Generation | ~11 tok/s |
| Real session, first turn | ~400 s |
| Real session, each turn after | **~4 s** |

The first turn of a session is slow and every turn after it is fast, because
Ollama caches the prompt prefix. Keeping that cache alive is what the server
settings above are for — without them the model is evicted between turns and
*every* turn pays the cold price.

This is the honest ceiling of a 35 B model on 6 GB of VRAM: generation stays
around 11 tok/s. The setup makes it consistent, not fast.

## Configuration

| Variable | Default | Description |
|---|---|---|
| `AGENT_NUM_CTX` | `65536` | Context window. Floor is ~32 k (Claude Code's own prompt is ~27 k). Raising it is reasonable once `kvCacheType = "q8_0"` is active; watch RAM in `doctor`. |
| `AGENT_FAST_NUM_CTX` | `16384` | Context for the small model used by Claude Code's side calls. |
| `OLLAMA_HOST` | `127.0.0.1:11434` | Address of the Ollama server. |
| `BENCH_PROMPT_TOKENS` | `27000` | Prompt size used by `bench`. |

## How it works

Two models are served:

- **`qwen3.6-agent`** (from `qwen3.6:35b-a3b`) does all the real work. It is a
  derived model that bakes in `num_ctx`, because Ollama's default of 4096
  silently truncates Claude Code's ~27 k-token prompt and leaves the agent with
  no project context at all.
- **`qwen3-fast`** (from `qwen3:1.7b`) serves Claude Code's small side calls —
  auto-mode permission checks, titles, summaries. It is pinned to CPU
  (`num_gpu 0`) so it cannot compete for VRAM with the 35 B. It is
  infrastructure, not a "fast mode" you choose.

  Four variables point at it, because Claude Code resolves those slots
  separately: `ANTHROPIC_SMALL_FAST_MODEL`, `ANTHROPIC_DEFAULT_HAIKU_MODEL`,
  `CLAUDE_CODE_AUTO_MODE_MODEL` and `CLAUDE_CODE_BG_CLASSIFIER_MODEL`. The
  last two are the auto-mode safety classifier, which falls back to the main
  model when unset — a 27 k-token prompt on the 35 B against a ~60 s budget.

## Troubleshooting

Start with `nix run .#doctor` — it checks all of the below and names the fix.

**The agent ignores the project.** Ollama is truncating the prompt:

```sh
journalctl -u ollama --since "10 min ago" | grep 'truncating input prompt'
```

Raise `AGENT_NUM_CTX` and re-run `setup`. A `Prompt is too long` error is the
opposite problem and is *working as intended* — it means Claude Code refused
to send a prompt that would have been silently truncated.

**`qwen3.6-agent is temporarily unavailable, so auto mode cannot determine the
safety of Bash`.** The server is fine; `ollama ps` will show the model loaded.
Read the model name in the message — it is the one the call actually used, so
`qwen3.6-agent` there means the classifier is running on the 35 B. Two causes,
and they stack:

- `CLAUDE_CODE_AUTO_MODE_MODEL` / `CLAUDE_CODE_BG_CLASSIFIER_MODEL` not
  pointing at `qwen3-fast`. `ANTHROPIC_SMALL_FAST_MODEL` does **not** cover
  the auto-mode classifier; `agent` exports all four.
- Only one runner loaded, so there is nowhere else for the call to go. Check
  `ollama ps` lists two rows with the small one at `100% CPU`, and that
  `OLLAMA_MAX_LOADED_MODELS` is `2` — unset is not the same as fine, because
  Ollama then evicts the small model to fit the 35 B.

The server-side signature is a 500 at just under a minute (the classifier's
own budget, well below `API_TIMEOUT_MS`):

```sh
journalctl -u ollama --since "10 min ago" | grep -E '\| 500 \| +59\.'   # systemd
grep -E '\| 500 \| +59\.' ~/.cache/local-ai-agent/ollama.log            # started by agent
```

**`API Error: Unable to connect to API (ConnectionRefused)` mid-session.**
Nothing is listening on 11434 any more. A server `agent` started dies only if
it is killed or OOMs (check
`~/.cache/local-ai-agent/ollama.log`); a server *you* manage can also be
stopped out from under the session — a `nixos-rebuild switch` that changes or
drops `services.ollama` will do exactly that. Restarting `agent` brings up a
fresh one.

**Every turn is slow, not just the first.** The model is being evicted between
turns, so `OLLAMA_KEEP_ALIVE` is not 24h on whichever server you are talking
to. `doctor` reports the value it actually sees.

**404 on `/v1/v1/messages`.** `ANTHROPIC_BASE_URL` ends in `/v1`; Claude Code
appends that itself.

**Stale global model pin.** `~/.claude/settings.json` may still contain
`"model": "qwen3.6:35b-a3b"` from an earlier `ollama launch`. `agent`
overrides it via `--model`, but clearing it avoids confusion elsewhere.

**First turn never finishes; `Execution error`.** Check `buff/cache` in
`free -h`. Most of the 35 B runs on CPU, so its ~22 GB of weights must stay in
the page cache; when they fall out, prefill drops from ~151 tok/s to ~35 tok/s
and the client gives up. Available RAM does *not* show this — lower
`AGENT_FAST_NUM_CTX` or `AGENT_NUM_CTX`. `doctor` checks this directly.

Note there is no swap configured on this machine, so exhausting RAM means an
OOM kill rather than a slowdown.
