# The hybrid launcher: a real Claude model reasoning, the local models doing
# the read-heavy grunt work in subagents.
#
# Why this exists. Running Claude Code entirely on Claude burns quota fast,
# because every turn re-sends the whole transcript and the transcript is
# mostly tool-result bulk — file reads, grep dumps, command output. Running it
# entirely on the local 35B is free but slow (~11 tok/s, minutes of cold
# prefill). Neither end of that is the right default for a 6GB box.
#
# The lever is that a subagent's transcript never enters the main context;
# only its final report does. So the main loop runs on Claude, and the
# subagents in .claude/agents/local-*.md are pinned to $AGENT_MODEL. A sweep
# that reads 40 files adds a few hundred tokens to the Claude conversation
# instead of tens of thousands, and that saving compounds on every later turn.
#
# Claude Code resolves a subagent's model straight from its frontmatter — in
# 2.1.223, `if(!i&&a&&a!=="inherit")l=a,i=Bi(a),s=a` — so an arbitrary model
# name there is honoured. What it does *not* have is more than one
# ANTHROPIC_BASE_URL, which is why local-ai-router has to exist.
#
# Like `agent`, this mutates nothing: all provisioning stays in `setup`.
{
  mkScript,
  pkgs,
  router,
  settings,
}:

let
  inherit (settings) hybrid;
in
mkScript {
  name = "hybrid-agent";

  runtimeInputs = [
    pkgs.claude-code
    pkgs.git
    router
  ];

  text = ''
    export ROUTER_BIN="${router}/bin/local-ai-router"
    export HYBRID_MODEL="''${HYBRID_MODEL:-${hybrid.remoteMainModel}}"
    CLASSIFIER_MODEL="''${HYBRID_CLASSIFIER_MODEL:-${hybrid.remoteClassifierModel}}"

    # Auth. Both modes exist because the supported one costs money and the
    # cheap one is undocumented.
    #
    #   subscription (default)  Claude Code only sends its OAuth token to a
    #                           base URL it considers first-party.
    #                           _CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL makes
    #                           it treat the router as one. The leading
    #                           underscore is upstream's, and it marks the
    #                           variable internal: it is unsupported and may
    #                           disappear in any release, which is the whole
    #                           reason --api-key exists as a fallback.
    #
    #   --api-key               Supported and stable, but it moves the session
    #                           off subscription limits and onto pay-per-token
    #                           billing. That trades a quota problem for a
    #                           money one, so it is not the default.
    AUTH_MODE=subscription
    args=()
    for arg in "$@"; do
      case "$arg" in
        --api-key) AUTH_MODE=api-key ;;
        *) args+=("$arg") ;;
      esac
    done

    if ! server_up; then
      ensure_server
    else
      maxl="$(server_env OLLAMA_MAX_LOADED_MODELS)"
      if [ -z "$maxl" ] || ! [ "$maxl" -ge 2 ] 2>/dev/null; then
        warn "hybrid: warning: the server already running has OLLAMA_MAX_LOADED_MODELS=''${maxl:-unset}"
        warn "hybrid: local subagents will evict each other; stop that server and let 'hybrid-agent' start one, or run local-ai-doctor"
      fi
    fi

    require_model "$AGENT_MODEL" "$NUM_CTX" "$AGENT_NUM_GPU"
    require_model "$FAST_MODEL" "$FAST_NUM_CTX" "$FAST_NUM_GPU"

    # The routing table, and the windows the router's truncation guard
    # compares against. Built here rather than baked into the router package
    # so that an AGENT_NUM_CTX override reaches the guard too.
    export ROUTER_LOCAL_MODELS="$AGENT_MODEL:$NUM_CTX,$FAST_MODEL:$FAST_NUM_CTX"
    export ROUTER_LOCAL_API="$API"
    ROUTER_USAGE_LOG="$(cache_dir)/router-usage.jsonl"
    export ROUTER_USAGE_LOG
    export ROUTER_LOCAL_TIMEOUT_S="''${ROUTER_LOCAL_TIMEOUT_S:-1800}"
    ensure_router

    # A router someone else started is reused, which means it may be routing
    # a different table than this launcher just computed. Worth catching here:
    # if $AGENT_MODEL is missing from it, every local subagent would silently
    # go to Anthropic — the exact opposite of the point.
    routed="$(router_local_models)"
    if ! printf '%s\n' "$routed" | grep -Fx "$AGENT_MODEL" >/dev/null; then
      die "the router on $ROUTER_ADDR does not route '$AGENT_MODEL' (it routes: $(printf '%s' "$routed" | tr '\n' ' ')) — it was started with a different table; stop it and re-run"
    fi

    PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    cd "$PROJECT_ROOT"

    # Everything goes through the router, which dispatches on the model name
    # in each request body. No trailing /v1: Claude Code appends /v1/messages
    # itself, and a 404 on /v1/v1/messages means it did.
    export ANTHROPIC_BASE_URL="http://$ROUTER_ADDR"
    export ANTHROPIC_MODEL="$HYBRID_MODEL"
    export ANTHROPIC_DEFAULT_OPUS_MODEL="$HYBRID_MODEL"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="$HYBRID_MODEL"

    if [ "$AUTH_MODE" = api-key ]; then
      if [ -z "''${ANTHROPIC_API_KEY:-}" ]; then
        die "hybrid: --api-key needs ANTHROPIC_API_KEY in the environment"
      fi
      say "hybrid: auth via ANTHROPIC_API_KEY (pay-per-token, not subscription)"
    else
      export _CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL=1
      # Leave ANTHROPIC_API_KEY/AUTH_TOKEN alone: setting either would make
      # Claude Code prefer it over the OAuth token this mode exists to use.
      say "hybrid: auth via your existing Claude Code login (subscription)"
    fi

    # Titles and summaries are small and tolerant, so they go to the 1.7B.
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="$FAST_MODEL"

    # These three stay remote, which is a deliberate reversal of nix/agent.nix.
    # There the main model *is* local and bounded at 65k, so a side call
    # carrying the transcript still fits. Here the transcript is a Claude one
    # and can be far larger than FAST_NUM_CTX, and ollama's answer to an
    # over-long prompt is to truncate it and mention that only in its own log
    # (failure mode 1). Auto mode would then keep approving tool calls from a
    # fragment of its prompt, quickly and wrongly. Context collapse is the
    # same story: it is handed the entire window by definition.
    export CLAUDE_CODE_AUTO_MODE_MODEL="$CLASSIFIER_MODEL"
    export CLAUDE_CODE_BG_CLASSIFIER_MODEL="$CLASSIFIER_MODEL"
    export CLAUDE_CONTEXT_COLLAPSE_MODEL="$CLASSIFIER_MODEL"

    # Deliberately NOT set, unlike in nix/agent.nix: the main model's window
    # is Claude's, and Claude Code already knows it. Pinning it to $NUM_CTX
    # here would make it compact a 200k-capable session at 65k. The local
    # subagents are left unguarded by this, which is what the router's own
    # truncation warning covers.
    unset CLAUDE_CODE_MAX_CONTEXT_TOKENS || true

    export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
    export API_TIMEOUT_MS="''${AGENT_API_TIMEOUT_MS:-1800000}"

    say "hybrid: $HYBRID_MODEL (remote) + $AGENT_MODEL (local subagents) via $ROUTER_ADDR"
    say "hybrid: side calls — titles $FAST_MODEL (local), classifiers $CLASSIFIER_MODEL (remote)"
    say "hybrid: root $PROJECT_ROOT"
    say "hybrid: token split so far — run local-ai-usage"

    exec claude --model "$HYBRID_MODEL" "''${args[@]+"''${args[@]}"}"
  '';
}
