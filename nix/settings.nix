# Single source of truth for model names and sizing.
#
# Everything here is consumed by nix/agent.nix, nix/hybrid.nix, nix/setup.nix,
# nix/doctor.nix, nix/router.nix and nix/bench.nix, so the derived models the
# setup builds and the values the doctor checks for can never drift apart.
{
  # The model as published upstream.
  baseModel = "qwen3.6:35b-a3b";

  # A thin derived model that exists only to bake in a usable num_ctx.
  # Ollama's server default is 4096 tokens, which silently truncates Claude
  # Code's ~27k-token system prompt down to ~2k and leaves the agent with no
  # project context at all. Model-level parameters override the server
  # default, so this needs no change to the system-wide ollama service.
  agentModel = "qwen3.6-agent";

  # Claude Code's base prompt alone is ~27k tokens, so anything below ~32k
  # leaves no room to actually read files. Override per-run with
  # AGENT_NUM_CTX.
  #
  # Sizing this is a cache tradeoff, not just a memory one: auto-compaction
  # rewrites the context and forces a full re-prefill, which costs ~3min at
  # the measured 155 tok/s cold prefill. A larger window means rarer
  # compactions, so this wants to be as large as the box allows.
  #
  # 131072 rather than 65536 because the earlier figure was sized against a
  # KV cost that turned out to be wrong by an order of magnitude. Measured
  # from the runner's own allocation at 65536:
  #
  #   llama_kv_cache: size = 680.00 MiB ( 65536 cells, 10 layers, 1/1 seqs),
  #                          K (q8_0): 340.00 MiB, V (q8_0): 340.00 MiB
  #   llama_kv_cache: size = 128.00 MiB ( 65536 cells,  1 layers, 1/1 seqs),
  #                          K (f16): 64.00 MiB, V (f16): 64.00 MiB
  #
  # 808 MiB total, or ~12.6 KB/token. Note "10 layers" and "1 layers" out of
  # 42: qwen35moe is a hybrid-attention architecture, so only a handful of
  # layers hold a KV cache at all and KV does not scale with depth the way it
  # does on a dense model. The 1.7B, which is dense, measures 58 KB/token
  # (952 MiB over 28 layers at 16384) — four and a half times more per token
  # than the model fourteen times its size.
  #
  # So each doubling here costs ~808 MiB, and it is spent in VRAM rather than
  # RAM (the allocation above is a CUDA0 buffer). That makes free VRAM the
  # binding constraint, not the page cache that bounds fastNumCtx: measured
  # 4987 MiB of 6144 MiB in use, so ~1157 MiB free and one doubling fits with
  # ~350 MiB to spare.
  #
  # That margin is thin, and the failure is quiet rather than loud — if KV no
  # longer fits, ollama keeps working and simply offloads fewer layers, which
  # shows up only as slower prefill. local-ai-doctor checks the fit for that
  # reason. If it reports trouble, 98304 costs ~404 MiB instead and is the
  # fallback.
  #
  # The ceiling is 262144 (the model's own context length, per ollama show),
  # not anything here.
  defaultNumCtx = "131072";

  # Claude Code makes frequent small side calls (permission/safety
  # classification in auto mode, titles, summaries) on its "small fast" model
  # slot. Pointing those at the 35B is what breaks auto mode: with
  # OLLAMA_NUM_PARALLEL=1 each side call queues behind a CPU-bound 35B
  # inference and exceeds its timeout, surfacing as "qwen3.6-agent is
  # temporarily unavailable, so auto mode cannot determine the safety of
  # Bash". A second, genuinely small model is served as its own runner and
  # answers in well under a second.
  #
  # This is infrastructure, not a user-facing "fast profile" — the 35B
  # remains the only model that does real work.
  fastBaseModel = "qwen3:1.7b";
  fastModel = "qwen3-fast";

  # Measured, not guessed. Claude Code's side calls are not small: observed
  # prompts of 10,295 tokens. An earlier value of 8192 here silently
  # truncated them to 4,098 —
  #
  #   truncating input prompt limit=4098 prompt=10295 keep=4
  #
  # which is worse than it looks: the classifier kept answering quickly, so
  # auto mode went on making safety decisions from a 40% fragment of its
  # prompt with nothing failing visibly.
  #
  # Note that the usable prompt is roughly num_ctx/2, since ollama reserves
  # room for the response (4096 -> limit 2050, 8192 -> limit 4098).
  #
  # 16384 is a compromise forced by RAM, not the value correctness alone
  # would pick. KV for this model is ~120KB/token, so 32768 costs 5.3GB
  # resident versus 3.3GB here — and that difference comes straight out of
  # the page cache the 22GB of main-model weights live in. Measured: at
  # 32768, buff/cache fell to 13GB, main-model prefill dropped from ~155 to
  # ~35 tok/s (disk-bound), and the first turn of a session stopped
  # completing at all.
  #
  # So side calls above ~8k tokens still truncate. local-ai-doctor reports
  # it. The real fix is kvCacheType = "q8_0" from the NixOS module, which
  # halves KV and makes 32768 affordable.
  fastNumCtx = "16384";

  # num_gpu=0 is load-bearing. Left on GPU the 1.7B claims ~3.2GB of this
  # box's 6GB VRAM, which collides with the 35B's offloaded layers: ollama
  # then evicts one model to load the other, and every alternation between
  # the main and fast slots costs a ~34s reload of the 22GB model. Pinning
  # the small model to CPU keeps both resident (measured: 0.44s fast, no
  # eviction) for ~2.4GB of RAM.
  #
  # The main model passes "" to let ollama decide its own offload split.
  agentNumGpu = "";
  fastNumGpu = "0";

  # The ollama server environment this setup requires. Consumed by the NixOS
  # module (as its option defaults) and by ensure_server in nix/common.sh, so
  # a self-started server is configured exactly like the systemd one — that
  # gap is how a session once ran for 10 minutes against a server with every
  # one of these at its default.
  #
  # Each entry is a measured failure, not tuning:
  #
  #   KEEP_ALIVE        the 5m default evicts the model between turns and
  #                     discards the ~27k-token KV cache; the next turn then
  #                     re-prefills for ~3min instead of ~5s.
  #   MAX_LOADED_MODELS unset leaves the decision to memory fitting, and the
  #                     35B always wins: loading it takes the runner count
  #                     back to 1 and evicts qwen3-fast, after which every
  #                     side call lands on the 35B. 2 keeps both resident.
  #   KV_CACHE_TYPE     q8_0 halves KV, which is what makes the two contexts
  #                     above affordable on 30GB. Requires flash attention.
  #   NUM_PARALLEL      deliberately 1: each slot allocates its own KV cache,
  #                     so >1 multiplies the ~23GB footprint rather than
  #                     improving throughput for a single user.
  serverEnv = {
    OLLAMA_KEEP_ALIVE = "24h";
    OLLAMA_MAX_LOADED_MODELS = "2";
    OLLAMA_KV_CACHE_TYPE = "q8_0";
    OLLAMA_FLASH_ATTENTION = "1";
    OLLAMA_NUM_PARALLEL = "1";
  };

  # Hybrid mode: Claude Code's main loop on a real Claude model, with the
  # read-heavy grunt work pushed into subagents pinned to the local models.
  #
  # The reason this needs a router at all: claude-code 2.1.223 has exactly
  # one ANTHROPIC_BASE_URL. Its only alternates are provider-specific
  # (ANTHROPIC_BEDROCK_BASE_URL, ANTHROPIC_VERTEX_BASE_URL,
  # ANTHROPIC_FOUNDRY_BASE_URL), so there is no way to say "this model over
  # here, that model over there". local-ai-router sits on loopback and
  # dispatches on the request body's "model" field instead.
  #
  # What this buys is not cheaper side calls — those are small. It is that a
  # subagent's transcript never enters the main context, only its final
  # report. A local-explore sweep that reads 40 files adds a few hundred
  # tokens to the Claude conversation rather than tens of thousands, and the
  # saving compounds because the transcript is re-sent on every later turn.
  hybrid = {
    # Loopback only, always. The router forwards a live Anthropic credential
    # and has no authentication of its own.
    routerAddr = "127.0.0.1:8787";

    remoteApi = "https://api.anthropic.com";

    # Sonnet rather than Opus by default: the problem hybrid mode exists to
    # solve is quota, and Sonnet costs a fraction per token. Override per-run
    # with HYBRID_MODEL=claude-opus-5.
    remoteMainModel = "claude-sonnet-5";

    # Auto-mode and background classification stay remote, which is a
    # deliberate reversal of what nix/agent.nix does. Those prompts carry the
    # whole transcript, and a Claude-main transcript is far larger than
    # fastNumCtx — ollama would truncate it silently (see failure mode 1) and
    # auto mode would go on making safety decisions from a fragment. Context
    # collapse needs the full window for the same reason.
    remoteClassifierModel = "claude-haiku-4-5-20251001";

    # Which models go to ollama is NOT configured here. local-ai-router
    # derives it from the same shell prelude every other script uses, as
    # "$AGENT_MODEL:$NUM_CTX,$FAST_MODEL:$FAST_NUM_CTX" — so the router
    # cannot disagree with the models setup actually built, and it learns
    # each window size for free. The windows are what the truncation guard
    # needs; a list of bare names here would have been a second place for
    # them to drift.
    #
    # Everything the router does not recognise goes to remoteApi, including
    # unrecognised paths: Claude Code also talks to its base URL for OAuth
    # refresh and policy limits, so default-remote is what keeps a
    # subscription session working.
  };
}
