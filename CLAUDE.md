# local-ai-agent

A Nix flake that drives Claude Code from a locally served Ollama model, so
agentic development works with no API calls leaving the machine — and, in
hybrid mode, a Claude main loop that delegates its bulk reading to that local
model instead of paying quota for it.

## Layout

```
flake.nix              wiring only — no logic
nix/settings.nix       model names, sizing, server env; single source of truth
nix/mk-script.nix      builds a script with the settings prelude + helpers
nix/common.sh          shared shell helpers (sourced, never executed)
nix/agent.nix          launcher: verify, warm, exec claude (all local)
nix/hybrid.nix         launcher: Claude main loop + local subagents
nix/router.nix         packaging for the model-dispatch router
nix/router.py          the router itself: dispatch on the request's model
nix/setup.nix          one-time provisioning (pull + ollama create)
nix/doctor.nix         diagnose every known failure mode
nix/bench.nix          measure prefill / cached prefill / generation
nix/usage.nix          local-vs-remote token split, from the router's log
nix/nixos-module.nix   services.local-ai-agent (opt-in; not needed to run)
```

Two launchers, for two different costs:

| | `agent` | `hybrid-agent` |
| --- | --- | --- |
| Main loop | `qwen3.6-agent`, local | a real Claude model |
| Subagents | local | local |
| Costs | wall-clock | quota, but much less of it |
| Needs an account | no | yes |

Commands: `local-ai-setup` (once), `local-ai-doctor`, `local-ai-bench`,
`local-ai-usage`, `agent`, `hybrid-agent`. All are in the devShell and
exposed as `nix run .#setup`, `.#doctor`, `.#bench`, `.#usage`, `.#hybrid`,
`.#router` and `nix run .` respectively.

Neither launcher mutates anything — all provisioning lives in `setup`, so
launching is fast and side-effect free. If a model is missing or has drifted,
both fail fast and point at `setup`.

## The performance model (measured on this box)

RTX 3060 Laptop, **6 GB VRAM**, 30 GB RAM. The 35B Q4_K_M is ~22 GB, and it
runs ~89% on CPU. The split is subtler than a layer count suggests — ollama
now reports `offloaded 42/42 layers to GPU`, yet `ollama ps` shows only
~2.8 GB of the 22.7 GB in VRAM, because the MoE expert tensors stay in RAM.
So the attention path is on the GPU and the experts, which dominate the
work, are not. (An earlier version of this file said "34 of 42 layers",
measured before KV cache quantization freed the VRAM to offload the rest.)

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

## Hybrid mode: Claude reasons, qwen does the reading

`agent` is free and slow. Running Claude Code entirely on Claude is fast and
burns quota quickly — and it does so for a reason worth naming precisely:
**what consumes the budget is tool-result bulk, not thinking.** Every turn
re-sends the whole transcript, and the transcript is mostly file reads, grep
output and command output. A 40-file sweep is paid for again on every
subsequent turn of that session.

`hybrid-agent` exists because of one asymmetry: **a subagent's transcript is
discarded when it finishes — only its final report reaches the main
conversation.** So the main loop runs on Claude, and the agents in
`.claude/agents/local-*.md` are pinned to `qwen3.6-agent`. The 40 files get
read on this machine; Claude receives a few hundred tokens of summary.

### Why a router is required

Claude Code 2.1.223 has exactly **one** `ANTHROPIC_BASE_URL`. Its only
alternates are provider-specific — `ANTHROPIC_BEDROCK_BASE_URL`,
`ANTHROPIC_VERTEX_BASE_URL`, `ANTHROPIC_FOUNDRY_BASE_URL`,
`ANTHROPIC_GOOGLE_CLOUD_BASE_URL` — so there is no supported way to say "this
model over there, that model over here". `nix/router.py` is that missing
piece: it speaks the same API on loopback and dispatches on the `model` field
of each request body.

What makes the whole design work is that subagent model names are honoured
verbatim. From the 2.1.223 bundle:

```js
del==="default"?TT():t.model,s=i,a=o?.model,l;if(!i&&a&&a!=="inherit")l=a,i=Bi(a),s=a
```

`a` is the agent definition's `model:`. Any string that is not `"inherit"` is
used as-is, which is what lets a frontmatter line name an ollama model.

Measured: the router adds nothing detectable. Three `qwen3-fast` round trips
direct to ollama were 0.126/0.088/0.089 s; the same three through the router
were 0.090/0.087/0.090 s.

### The routing rule: default-remote

Only the models in `ROUTER_LOCAL_MODELS` go to ollama. **Everything else goes
to Anthropic, including paths the router does not recognise** — Claude Code
also talks to its base URL for OAuth refresh and policy limits
(`firstPartyApi: refreshOAuth failed`, `loadPolicyLimits` in the bundle), and
swallowing those breaks a subscription session.

The cost of that choice is that an unrouted model name does not fail — it
quietly becomes a billable Claude call, which is the exact opposite of the
point. Three things guard against it, because this is the failure that would
be invisible:

- `hybrid-agent` refuses to start if the live router does not route
  `$AGENT_MODEL`, naming what it does route instead.
- `local-ai-doctor` checks the same thing, plus that every
  `.claude/agents/local-*.md` names exactly `agentModel` from
  `nix/settings.nix`.
- `local-ai-usage` reports the local/remote token split, so a regression
  shows up as a number rather than as a surprise at the end of the month.

The table is built by the launcher, not baked into the router package, so an
`AGENT_NUM_CTX` override reaches the truncation guard too.

### Auth: two modes, neither free of tradeoffs

Pointing `ANTHROPIC_BASE_URL` at the router means Claude Code is no longer
talking to `api.anthropic.com` directly, and that changes how it
authenticates.

- **subscription (default).** Claude Code only sends its OAuth token to a base
  URL it considers first-party. `_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL`
  makes it treat the router as one. The leading underscore is upstream's and
  it means what it looks like: internal, undocumented, free to disappear in
  any release. That is the entire reason the other mode exists.
- **`--api-key`.** Supported and stable, but it moves the session off
  subscription limits and onto pay-per-token billing — it converts a quota
  problem into a money one. Hence not the default.

The router never inspects a credential; it forwards whatever header arrives.
It also refuses to bind anything but loopback, and its access log is
deliberately silenced — it handles a live token and has no authentication of
its own.

### What side calls do here, and why it differs from `agent`

| Slot | `agent` | `hybrid-agent` | Why |
| --- | --- | --- | --- |
| main | local 35B | Claude | reasoning |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL` | `qwen3-fast` | `qwen3-fast` | titles, summaries: small and tolerant |
| `CLAUDE_CODE_AUTO_MODE_MODEL` | `qwen3-fast` | **Claude Haiku** | carries the whole transcript |
| `CLAUDE_CODE_BG_CLASSIFIER_MODEL` | `qwen3-fast` | **Claude Haiku** | same |
| `CLAUDE_CONTEXT_COLLAPSE_MODEL` | — | **Claude Haiku** | gets the entire window by definition |
| `CLAUDE_CODE_MAX_CONTEXT_TOKENS` | `$NUM_CTX` | **unset** | the window is Claude's now |

The three reversals are deliberate and are the same single reason: in `agent`
the main model *is* local and bounded at 65k, so a side call carrying the
transcript still fits. In hybrid mode the transcript is a Claude one and can
be far larger than `fastNumCtx` — and ollama's response to an over-long
prompt is to truncate it and mention that only in its own log (failure mode
1). Auto mode would then go on approving tool calls from a fragment of its
prompt: quickly, and wrongly. A silently-truncated safety classifier is worse
than a remote one that costs a fraction of a cent.

`CLAUDE_CODE_MAX_CONTEXT_TOKENS` being unset follows from the same place.
Pinning it to `$NUM_CTX` would make Claude Code compact a 200k-capable
session at 65k. The consequence is that nothing bounds a *local subagent's*
prompt, so the router warns when one exceeds `num_ctx/2`:

```
router: WARNING: qwen3-fast prompt is ~15019 tokens but only ~8192 are usable
at num_ctx=16384 — ollama will truncate it silently
```

That warning is the guard working. `local-ai-doctor` counts them.

### An upside specific to this mode

With the main loop remote, the local 35B's single slot serves **only**
subagents. There is no longer a main-session KV cache for a side call to
overwrite, so failure mode 2's worst consequence — a classifier attempt
destroying the conversation's prefix and making the next real turn re-prefill
— does not apply here at all.

### What it costs

Wall-clock, and not a little. Each *distinct* subagent type is its own cold
prefill, because its prompt prefix does not match anything already in the
slot: ~3 min for a 27k prompt at the measured 155 tok/s, then ~11 tok/s to
write its report. Repeat calls to the *same* agent reuse the prefix and are
far cheaper, which is why there are two broad agents rather than six narrow
ones — and why adding a third should be a deliberate decision.

So this is a money-for-time trade, and it is only worth taking for work that
is wide, shallow and boring. Reasoning, design and anything subtle should stay
on Claude; delegating those to a 35B does not save anything, it just produces
a confident answer that has to be redone.

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

The two windows do **not** compete for the same resource, which is the thing
an earlier version of this section got wrong. Measured from the runners'
own allocation lines:

| Model | num_ctx | KV allocated | Per token | Where |
| --- | --- | --- | --- | --- |
| `qwen3.6-agent` (35B) | 65536 | **808 MiB** | ~12.6 KB | CUDA0 (VRAM) |
| `qwen3-fast` (1.7B) | 16384 | **952 MiB** | ~58 KB | CPU (RAM) |

```
llama_kv_cache: size = 680.00 MiB ( 65536 cells, 10 layers, 1/1 seqs), K (q8_0): 340.00 MiB, V (q8_0): 340.00 MiB
llama_kv_cache: size = 128.00 MiB ( 65536 cells,  1 layers, 1/1 seqs), K (f16):   64.00 MiB, V (f16):   64.00 MiB
llama_kv_cache: size = 952.00 MiB ( 16384 cells, 28 layers, 1/1 seqs), K (q8_0): 476.00 MiB, V (q8_0): 476.00 MiB
```

**The 35B costs four and a half times less per token than the 1.7B.** Read
the layer counts: `10 layers` and `1 layers` out of 42. `qwen35moe` is a
hybrid-attention architecture, so only a handful of layers hold a KV cache at
all, while the dense 1.7B pays for all 28. KV does not scale with parameter
count; it scales with how many layers do full attention.

This inverts the old conclusion that the main window was the expensive one:

- `defaultNumCtx` (main) = **131072**. Each doubling costs ~808 MiB **of
  VRAM**, so free VRAM is the constraint — not the page cache. Measured 4987
  of 6144 MiB in use, leaving ~1157 MiB, so one doubling fits with ~350 MiB
  spare. The ceiling is 262144, the model's own context length.
- `fastNumCtx` (classifier) = **16384**. This is the genuinely expensive one,
  at 58 KB/token in RAM, and it is what failure mode 4 was really about.
  Side calls above ~8k tokens truncate — a real but lesser cost than losing
  main-model prefill speed. Claude Code has been observed sending
  10,295-token side calls.

When raising the main window, watch **VRAM and the layer offload**, not the
page cache. The failure is quiet: if KV stops fitting, ollama does not error,
it offloads fewer layers and prefill simply gets slower. `local-ai-doctor`
checks `offloaded N/N layers to GPU` and reports the measured KV for that
reason. Note that `42/42` does not mean the weights are in VRAM — only
~2.8 GB of the 22.7 GB is; the MoE expert tensors stay in RAM, which is why
the page-cache cliff still exists and why this is ~89% a CPU workload.

`fastNumCtx` is still bounded by the page cache, and there is no swap on this
machine — exhausting RAM means an OOM kill, not a slowdown.

### What raising it actually buys, per launcher

- **`agent`** — directly. `CLAUDE_CODE_MAX_CONTEXT_TOKENS` is pinned to
  `$NUM_CTX`, so auto-compaction fires as a fraction of it. At 65536 a ~27k
  system prompt leaves the session roughly 40% full before any work happens,
  which is why compaction arrived so quickly; at 131072 that same prompt is
  ~20%, so compactions roughly halve.
- **`hybrid-agent`** — not for the main loop. There
  `CLAUDE_CODE_MAX_CONTEXT_TOKENS` is deliberately unset and compaction is
  governed by Claude's own window, which this setting cannot change. What it
  does buy is headroom for **local subagents**: a larger window for
  `local-explore` before the router's truncation warning fires.

One caveat in both cases: a bigger window permits a bigger prompt, and cold
prefill is linear in prompt size at ~155 tok/s. Compaction is still the
thing worth avoiding — warm turns stay ~4 s regardless — but a 120k-token
cold prefill is minutes, so the win is fewer compactions, not faster turns.

Changing either value needs `nix run .#setup` to rebuild the derived model;
`agent` and `hybrid-agent` will refuse to start until it matches, naming the
drift.

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
  - `'''` inside a `''…''` Nix string is the escape for a literal `''`, not a
    quote followed by an interpolation. So a shell line like
    `'${want:-unset}'` written inside one silently becomes something else
    entirely — statix reported it as an "unquoted URI expression" several
    lines further on, which is not a useful pointer. Rephrase to avoid the
    adjacency rather than trying to escape your way out.
- `nix/router.py` is stdlib-only on purpose: it sits in the path of every API
  call a hybrid session makes, so a dependency there is one more thing that
  can take a session down. `writePython3Bin` runs flake8 at build time;
  `E501` is ignored because the comments explaining each failure mode are
  worth more than a 79-column limit.
- The router's `/healthz` is the interface `doctor` and `hybrid-agent` use to
  ask what it is *actually* routing, rather than inferring it from `/proc`.
  A router someone left running with a different table is the drift worth
  catching, and only the router knows how it parsed its own.
