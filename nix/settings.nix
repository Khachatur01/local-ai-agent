# Single source of truth for model names and sizing.
#
# Everything here is consumed by nix/agent.nix, nix/setup.nix, nix/doctor.nix
# and nix/bench.nix, so the derived models the setup builds and the values the
# doctor checks for can never drift apart.
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
  # compactions, bounded by RAM.
  defaultNumCtx = "65536";

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
}
