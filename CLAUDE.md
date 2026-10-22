# local-ai-agent

A Nix flake that runs Claude Code against a locally served Ollama model, so
agentic development works with no API calls leaving the machine.

## Layout

```
flake.nix              wiring only — no logic
nix/settings.nix       model names, sizing, server env; single source of truth
nix/mk-script.nix      builds a script with the settings prelude + helpers
nix/common.sh          shared shell helpers (sourced, never executed)
nix/agent.nix          launcher: verify, warm, exec claude
nix/setup.nix          one-time provisioning (pull + ollama create)
nix/doctor.nix         diagnose every known failure mode
nix/bench.nix          measure prefill / cached prefill / generation
nix/nixos-module.nix   services.local-ai-agent (opt-in; not needed to run)
```

Commands: `local-ai-setup` (once), `local-ai-doctor`, `local-ai-bench`,
`agent`. All four are in the devShell and exposed as `nix run .#setup`,
`.#doctor`, `.#bench` and `nix run .` respectively.

`agent` never mutates anything — all provisioning lives in `setup`, so
launching is fast and side-effect free. If a model is missing or has drifted,
`agent` fails fast and points at `setup`.

## The performance model (measured on this box)

RTX 3060 Laptop, **6 GB VRAM**, 30 GB RAM. The 35B Q4_K_M is ~22 GB, so only
34 of 42 layers offload and it runs ~89% on CPU.

| What | Measured |
| --- | --- |
| Cold prefill, 27k prompt | 176.6 s (**155 tok/s**) |
| Cached prefill, same prompt | 5.1 s |
| Generation | ~11 tok/s |
| Real session, turn 1 (cold, 19.4k tokens) | **402 s** |
| Real session, turn 2 (resumed, +18 tokens) | **4 s** |

**The prefix cache is the entire performance story.** A session costs minutes
on its first turn and ~4 seconds per turn after that. Everything in the
configuration exists to keep that cache alive.

### Cache hygiene: verified good

A real two-turn session re-prefilled only the 18-token delta (19,362 →
19,380 tokens, 402 s → 4 s). So Claude Code's prompt prefix is **stable across
turns** — no volatile early content (date, cwd, git state) is busting the
cache. This was an open worry; it is not a problem. If turn-over-turn latency
ever regresses to minutes, re-check this first:

```sh
# whichever server is serving: the journal when systemd-managed, else the
# log ensure_server writes
journalctl -u ollama --since "10 min ago" 2>/dev/null \
  | grep -E 'n_ctx_slot|task.n_tokens'
grep -E 'n_ctx_slot|task.n_tokens' ~/.cache/local-ai-agent/ollama.log
```

Two consecutive turns should show nearly identical `task.n_tokens` with only
the second being fast.

## Failure mode 1: silent context truncation

Ollama's default context is **4096 tokens**. Claude Code's system prompt is
~27k, so Ollama silently discarded ~92% of every prompt:

```
msg="truncating input prompt" limit=2050 prompt=26693 keep=4
```

The agent then ran with no system prompt, no project files and no tool
results — it looked careless rather than broken. The fix is the derived model
`qwen3.6-agent`, which bakes in `num_ctx`; model-level parameters override the
server default, so no change to the system-wide `services.ollama` unit is
needed.

`CLAUDE_CODE_MAX_CONTEXT_TOKENS` is pinned to the real `num_ctx` for the same
reason. Without it Claude Code assumes a 200k window and lets Ollama truncate.
With it, an over-long prompt produces a clean `Prompt is too long` error
instead of silent data loss — that error is the guard working, not a bug.

## Failure mode 2: the classifier running on the 35B

Claude Code makes small side calls (auto-mode permission/safety
classification, titles, summaries) that must not land on the 35B. With
`OLLAMA_NUM_PARALLEL=1` they queue behind a CPU-bound inference, and the
classifier has its own budget of roughly **60 seconds** — far below the
`API_TIMEOUT_MS` the launcher sets for real turns. They fail as:

```
qwen3.6-agent is temporarily unavailable, so auto mode cannot
determine the safety of Bash right now.
```

**Read the model name in that message.** It is the model the call actually
used, and `ANTHROPIC_SMALL_FAST_MODEL` / `ANTHROPIC_DEFAULT_HAIKU_MODEL` do
**not** cover this path. Claude Code 2.1.223 resolves the auto-mode
classifier from `CLAUDE_CODE_AUTO_MODE_MODEL` and falls back to the main
model when it is unset; background classification uses
`CLAUDE_CODE_BG_CLASSIFIER_MODEL`. All four are set, and all four must stay
off `$AGENT_MODEL`.

What this looked like in the log — one runner, 65536 ctx, so every side call
was being served by the 35B:

```
slot operator(): id 0 | task 389 | new prompt, n_ctx_slot = 65536, task.n_tokens = 26882
[GIN] | 500 | 59.997931977s | POST "/v1/messages?beta=true"
srv  stop: cancel task, id_task = 389
```

Three things compound there:

1. The classifier prompt is the whole transcript (~27k tokens) behind a
   prefix that does not match the conversation — `f_sim = 0.000, lcp = 3`.
   So it is a **cold** prefill: ~3 minutes against a ~60 second budget.
2. The 500 is the client hanging up, not a server fault. `ollama ps` shows
   the model loaded and healthy throughout.
3. Worst of all, those calls share the main model's single slot, so each
   attempt **overwrites the conversation's KV cache**. The next real turn
   then re-prefills too, which is how three failed permission checks turned
   into a 10-minute session that got nothing done.

Raising `OLLAMA_NUM_PARALLEL` is the wrong fix: each slot allocates its own
KV cache, so two slots at 65k context roughly doubles the ~23 GB footprint.

A permission rule is cheaper than a correct classifier call. Anything matched
by `permissions.allow` in `.claude/settings.json` never reaches the
classifier at all — `Bash(git add *)` and `Bash(git commit *)` are there for
that reason.

## Failure mode 3: the two models evicting each other

`qwen3-fast` is pinned to CPU with `num_gpu 0`, and that is load-bearing. On
the GPU the 1.7B claims ~3.2 GB of the 6 GB VRAM the 35B's offloaded layers
need, so Ollama evicts one model to load the other — **~34 s reload on every
switch between slots**, worse than the timeout it was meant to fix.
`keep_alive` does not prevent it; eviction is driven by memory fitting.

Pinned to CPU, both stay resident (0.44 s fast, 0.46 s main, no eviction) for
~2.4 GB of RAM. `ollama ps` should show two rows with the small one at
`100% CPU`. `local-ai-doctor` fails if this drifts.

`num_gpu 0` alone is **not** enough, though. With `OLLAMA_MAX_LOADED_MODELS`
unset, Ollama still decides by memory fitting and the 35B still wins:

```
# qwen3-fast loads, then the 35B loads
time=11:11:32 msg="loaded runners" count=1
time=11:12:21 msg="loaded runners" count=1
```

The count never reaches 2. After that every request — including the side
calls — is served by the one remaining runner, which is how failure mode 2
gets triggered even with the small model configured correctly. The server
settings below are a prerequisite for this one, not an optimisation.

## Server settings

Ollama evicts idle models after 5 minutes, which discards the KV cache and
makes the next turn pay the cold price. This is the single most expensive
default here, and four others matter — `OLLAMA_KEEP_ALIVE=24h`,
`OLLAMA_MAX_LOADED_MODELS=2`, `OLLAMA_KV_CACHE_TYPE=q8_0`,
`OLLAMA_FLASH_ATTENTION=1`, `OLLAMA_NUM_PARALLEL=1`, all from `serverEnv` in
`nix/settings.nix`.

**This flake applies them itself and depends on no host configuration.**
`ensure_server` starts ollama when nothing is listening on 11434 and passes
all five on explicitly, because a process started that way inherits nothing
from anywhere. That server runs as the invoking user, so its model store is
`~/.ollama/models`.

This is deliberate, and it is the one invariant to protect when changing
anything here: the project has to work on a machine whose system
configuration knows nothing about it. An earlier version expected
`services.ollama` to exist and only decorated it, which split one working
setup across two repositories — and when `services.ollama` was later dropped
from the host config, a `nixos-rebuild switch` took the server away
mid-session and the agent died with
`API Error: Unable to connect to API (ConnectionRefused)`.

`nix/nixos-module.nix` still exists for anyone who wants the service managed
by systemd instead, and it now enables `services.ollama` on its own rather
than asserting that someone else did. It is strictly opt-in: nothing in the
default path reads it. Note that the service's `/var/lib/ollama/models` is a
different store from a user-started server's `~/.ollama/models` — switching
between them means pulling the 22 GB again.

## Failure mode 4: the page-cache cliff

Most of the 35B runs on CPU, so its ~22 GB of weights must stay in the page
cache. When they do not, prefill becomes disk-bound and the first turn of a
session stops completing at all.

This was triggered by raising `fastNumCtx` to 32768, which cost 5.3 GB
resident instead of 3.3 GB. That 2 GB came straight out of the page cache:

| buff/cache | Main-model prefill | First turn |
| --- | --- | --- |
| 20 GB | ~151 tok/s | completes in ~175 s |
| 13 GB | ~35 tok/s | client gives up, `500` after ~4-5 min |

**Available RAM does not predict this** — it read ~12 GB in both cases. The
symptom is a bare `Execution error` from Claude Code plus a `500` in the
ollama log with a multi-minute duration. `local-ai-doctor` now checks
`buff/cache` against the weight size instead of free memory.

## Sizing the two contexts

These two values compete for the same 30 GB, and there is no setting that
makes both ideal:

- `defaultNumCtx` (main) = **65536**. Auto-compaction forces a full cold
  re-prefill, so a bigger window means rarer compactions.
- `fastNumCtx` (classifier) = **16384**. KV is ~120 KB/token for this model,
  so each doubling is expensive. Side calls above ~8k tokens truncate, which
  is a real but lesser cost than losing main-model prefill speed — Claude
  Code has been observed sending 10,295-token side calls.

Note that the usable prompt is roughly `num_ctx/2`; ollama reserves the rest
for the response (4096 → limit 2050, 8192 → limit 4098).

Raising either is reasonable **after** `OLLAMA_KV_CACHE_TYPE=q8_0` is active,
which roughly halves KV. Watch `page cache` in `local-ai-doctor` rather than
available memory, and there is no swap on this machine — exhausting RAM means
an OOM kill, not a slowdown.

## Conventions

- Logic lives in `nix/`; `flake.nix` is wiring only. Settings belong in
  `nix/settings.nix` so `setup` and `doctor` cannot disagree.
- `ANTHROPIC_BASE_URL` must **not** end in `/v1` — Claude Code appends
  `/v1/messages`. A `404 /v1/v1/messages` in the Ollama log means it did.
- Scripts run under `set -euo pipefail` via `writeShellApplication`, which
  also runs shellcheck and **fails on info-level findings**. Two traps have
  bitten repeatedly here, both already commented in `nix/common.sh`:
  - `grep` exiting 1 on no-match inside `$( )` aborts the script. The
    condition you are trying to *detect* is the one that kills you. Use
    `|| true`.
  - `head -c` / `grep -q` ending a pipeline SIGPIPEs upstream producers, and
    `pipefail` turns that into exit 141 — even on success.
