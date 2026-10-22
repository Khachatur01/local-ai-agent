# The launcher: verify, warm, and hand off to Claude Code.
#
# Everything mutating lives in nix/setup.nix. This script only checks that the
# models it needs already exist in the shape it expects.
{ mkScript, pkgs }:

mkScript {
  name = "agent";

  runtimeInputs = [
    pkgs.claude-code
    pkgs.git
  ];

  text = ''
    if ! server_up; then
      ensure_server
    else
      # Something else is already serving, so ensure_server's settings never
      # reached it — it could be the ollama unit, or a bare "ollama serve"
      # someone left running. Max-loaded is the one worth checking inline:
      # below 2 the classifier model gets evicted, every side call lands on
      # the 35B, and auto mode starts failing with "temporarily unavailable"
      # several minutes into the session rather than here.
      maxl="$(server_env OLLAMA_MAX_LOADED_MODELS)"
      if [ -z "$maxl" ] || ! [ "$maxl" -ge 2 ] 2>/dev/null; then
        warn "agent: warning: the server already running has OLLAMA_MAX_LOADED_MODELS=''${maxl:-unset}"
        warn "agent: auto mode will time out on the 35B; stop that server and let 'agent' start one, or run local-ai-doctor"
      fi
    fi

    require_model "$AGENT_MODEL" "$NUM_CTX" "$AGENT_NUM_GPU"
    require_model "$FAST_MODEL" "$FAST_NUM_CTX" "$FAST_NUM_GPU"

    # Loading the small model costs ~3-5s even warm from page cache, which is
    # enough to blow the timeout on the first auto-mode safety check. Warm it
    # in the background so that load overlaps with Claude Code's own startup
    # instead of landing on the first classification.
    if ! model_resident "$FAST_MODEL"; then
      warm_model "$FAST_MODEL" &
    fi

    # Run from the repository root so Claude Code discovers CLAUDE.md,
    # .claude/ and the full file tree rather than whichever subdirectory the
    # shell happened to be sitting in. This is also what makes the flake
    # usable from any project via `nix run`.
    PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    cd "$PROJECT_ROOT"

    # Claude Code appends /v1/messages itself, so the base URL must NOT
    # already end in /v1. A 404 on /v1/v1/messages means it did.
    export ANTHROPIC_BASE_URL="$API"
    export ANTHROPIC_AUTH_TOKEN="ollama"
    export ANTHROPIC_MODEL="$AGENT_MODEL"
    export ANTHROPIC_DEFAULT_OPUS_MODEL="$AGENT_MODEL"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="$AGENT_MODEL"

    # Side calls go to the small model so they never queue behind a 35B
    # inference. Keep these two off $AGENT_MODEL or auto mode starts timing
    # out again.
    export ANTHROPIC_SMALL_FAST_MODEL="$FAST_MODEL"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="$FAST_MODEL"
    export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

    # Auto mode's safety classifier does NOT use either of the two variables
    # above. In Claude Code 2.1.223 it resolves its own model from
    # CLAUDE_CODE_AUTO_MODE_MODEL and falls back to the main model when that
    # is unset, so every Bash permission check ran on the 35B:
    #
    #   qwen3.6-agent is temporarily unavailable, so auto mode cannot
    #   determine the safety of Bash right now.
    #
    # Note the model it names. Those calls carry the whole transcript (~27k
    # tokens) behind a prefix that does not match the conversation
    # (f_sim = 0.000 in the ollama log), so each one is a ~3min cold prefill
    # against a hard ~60s classifier budget — hence "500 | 59.99s" followed
    # by "srv stop: cancel task". Worse, they share the main model's single
    # slot, so every attempt also overwrites the conversation's KV cache and
    # makes the next real turn re-prefill from scratch.
    export CLAUDE_CODE_AUTO_MODE_MODEL="$FAST_MODEL"
    export CLAUDE_CODE_BG_CLASSIFIER_MODEL="$FAST_MODEL"

    # Headroom, not a fix for any specific bug. A cold first turn spends
    # minutes in prefill before the first token (measured: 175s for a 21k
    # prompt at ~151 tok/s), and a long session can approach the 5 minute
    # default. Warm turns are ~4s and never come close.
    export API_TIMEOUT_MS="''${AGENT_API_TIMEOUT_MS:-1800000}"

    # Claude Code does not know this model, so it would assume a 200k window
    # and only auto-compact at 200k — while ollama silently truncates at
    # num_ctx. Telling it the real window makes compaction fire before
    # anything gets dropped.
    export CLAUDE_CODE_MAX_CONTEXT_TOKENS="$NUM_CTX"

    say "agent: $AGENT_MODEL @ $NUM_CTX ctx (fast: $FAST_MODEL @ $FAST_NUM_CTX) -> $API"
    say "agent: root $PROJECT_ROOT"

    # --model on the command line overrides any stale "model" left in
    # ~/.claude/settings.json by `ollama launch`.
    exec claude --model "$AGENT_MODEL" "$@"
  '';
}
