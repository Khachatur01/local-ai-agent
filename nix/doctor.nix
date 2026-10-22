# Turns the failure modes this setup already hit into one diagnostic.
#
# Every check names the fix, because each of these failed silently at least
# once: truncated context looked like a careless agent, and model eviction
# looked like a flaky server.
{ mkScript, pkgs }:

mkScript {
  name = "local-ai-doctor";

  # git: the subagent-definition check resolves the project root.
  runtimeInputs = [ pkgs.git ];

  text = ''
    fails=0
    warns=0

    ok() { say "  ok    $*"; }
    info() { say "  info  $*"; }
    bad() {
      say "  FAIL  $1"
      say "        fix: $2"
      fails=$((fails + 1))
    }
    meh() {
      say "  warn  $1"
      say "        fix: $2"
      warns=$((warns + 1))
    }

    # Recent server log, from whichever place this server writes to.
    server_log() {
      if systemd_managed; then
        journalctl -u ollama --since "1 hour ago" --no-pager 2>/dev/null || true
      else
        tail -n 20000 \
          "''${XDG_CACHE_HOME:-$HOME/.cache}/local-ai-agent/ollama.log" \
          2>/dev/null || true
      fi
    }

    say "server"
    if server_up; then
      ok "reachable at $API"
      if systemd_managed; then
        info "systemd-managed (services.ollama)"
      else
        # Worth naming, and not only for the settings: a server running as a
        # normal user reads that user's own model store rather than the
        # service's /var/lib/ollama — a different set of models.
        store="$(server_env OLLAMA_MODELS)"
        info "not systemd-managed — models from ''${store:-$HOME/.ollama/models}"
      fi
    else
      bad "no ollama server at $API" \
        "run 'agent', which starts its own correctly configured server — or start yours (systemctl start ollama)"
      say ""
      say "cannot check models without a server; stopping here."
      exit 1
    fi

    say ""
    say "models"
    for spec in "$AGENT_MODEL:$NUM_CTX:$AGENT_NUM_GPU" "$FAST_MODEL:$FAST_NUM_CTX:$FAST_NUM_GPU"; do
      m="''${spec%%:*}"
      rest="''${spec#*:}"
      want_ctx="''${rest%%:*}"
      want_gpu="''${rest#*:}"

      if ! have_model "$m"; then
        bad "model '$m' is missing" "nix run .#setup"
        continue
      fi

      got_ctx="$(model_param "$m" num_ctx)"
      if [ "$got_ctx" = "$want_ctx" ]; then
        ok "$m num_ctx=$got_ctx"
      else
        bad "$m has num_ctx=''${got_ctx:-unset}, expected $want_ctx" \
          "nix run .#setup (a too-small num_ctx silently truncates the prompt)"
      fi

      got_gpu="$(model_param "$m" num_gpu)"
      if [ "$want_gpu" = "" ]; then
        info "$m num_gpu=auto"
      elif [ "$got_gpu" = "$want_gpu" ]; then
        ok "$m num_gpu=$got_gpu (pinned off the GPU)"
      else
        # This is the eviction guard. Without it the 1.7B takes ~3.2GB of the
        # 6GB VRAM the 35B needs, and ollama evicts one model to load the
        # other — ~34s reload on every switch between slots.
        bad "$m has num_gpu=''${got_gpu:-auto}, expected $want_gpu" \
          "nix run .#setup — on the GPU this model evicts the 35B, costing a ~34s reload per slot switch"
      fi

      if model_resident "$m"; then
        info "$m is loaded"
      else
        info "$m is not loaded right now"
      fi
    done

    say ""
    say "server settings (cache preservation)"

    keep="$(server_env OLLAMA_KEEP_ALIVE)"
    case "$keep" in
      "")
        # The single most expensive default here: losing the KV cache turns a
        # ~5s prefill into a ~3min one.
        meh "OLLAMA_KEEP_ALIVE is unset (ollama defaults to 5m)" \
          "let 'agent' start the server (it applies all five settings), or set OLLAMA_KEEP_ALIVE=24h on whatever manages this one — idle eviction discards the ~27k-token KV cache and the next turn re-prefills for ~3min"
        ;;
      5m | 300 | 300s)
        meh "OLLAMA_KEEP_ALIVE=$keep is the short default" \
          "set OLLAMA_KEEP_ALIVE=24h on whatever manages this server"
        ;;
      *)
        ok "OLLAMA_KEEP_ALIVE=$keep"
        ;;
    esac

    par="$(server_env OLLAMA_NUM_PARALLEL)"
    if [ -z "$par" ] || [ "$par" = "1" ]; then
      ok "OLLAMA_NUM_PARALLEL=''${par:-default}"
    else
      bad "OLLAMA_NUM_PARALLEL=$par" \
        "set it to 1 — each slot allocates its own KV cache, so >1 multiplies the ~23GB footprint"
    fi

    flash="$(server_env OLLAMA_FLASH_ATTENTION)"
    if [ "$flash" = "1" ]; then
      ok "OLLAMA_FLASH_ATTENTION=1"
    else
      meh "OLLAMA_FLASH_ATTENTION is not 1" \
        "set OLLAMA_FLASH_ATTENTION=1 on whatever manages this server — it is required for KV cache quantization"
    fi

    kv="$(server_env OLLAMA_KV_CACHE_TYPE)"
    if [ -n "$kv" ]; then
      ok "OLLAMA_KV_CACHE_TYPE=$kv"
    else
      info "OLLAMA_KV_CACHE_TYPE unset (f16) — q8_0 halves KV memory"
    fi

    # "Unset" is not the same as "fine" here, which is why this used to pass
    # on a broken server: with no value ollama decides by memory fitting and
    # the 35B wins, so loading it drops the runner count back to 1 and takes
    # qwen3-fast with it ("loaded runners count=1" in the log). Every side
    # call then lands on the 35B.
    maxl="$(server_env OLLAMA_MAX_LOADED_MODELS)"
    if [ -z "$maxl" ] || [ "$maxl" = "0" ]; then
      bad "OLLAMA_MAX_LOADED_MODELS is ''${maxl:-unset} (ollama decides by memory fitting)" \
        "set OLLAMA_MAX_LOADED_MODELS=2 on whatever manages this server — otherwise the 35B evicts $FAST_MODEL, and auto mode's safety checks then run on the 35B and time out"
    elif [ "$maxl" -ge 2 ] 2>/dev/null; then
      ok "OLLAMA_MAX_LOADED_MODELS=$maxl"
    else
      bad "OLLAMA_MAX_LOADED_MODELS=$maxl" \
        "needs to be >= 2 so the agent and classifier models stay resident together"
    fi

    say ""
    say "resources"
    if command -v nvidia-smi >/dev/null 2>&1; then
      info "VRAM $(nvidia-smi --query-gpu=memory.used,memory.total \
        --format=csv,noheader 2>/dev/null | head -1)"
    else
      info "no nvidia-smi; skipping VRAM check"
    fi

    # The quiet failure mode for defaultNumCtx. On this architecture KV is a
    # CUDA0 buffer, so raising num_ctx spends VRAM, not the page cache that
    # bounds the small model. When it stops fitting, ollama does not fail — it
    # offloads fewer layers and carries on, and the only symptom is slower
    # prefill. So check the offload itself rather than trusting the setting.
    offload="$(server_log | grep -oE 'offloaded [0-9]+/[0-9]+ layers to GPU' | tail -1 || true)"
    if [ -n "$offload" ]; then
      got_l="''${offload#offloaded }"
      got_l="''${got_l%%/*}"
      want_l="''${offload#*/}"
      want_l="''${want_l%% *}"
      if [ "$got_l" = "$want_l" ]; then
        ok "$offload"
      else
        meh "only $offload — KV may have crowded the weights out of VRAM" \
          "lower AGENT_NUM_CTX (each doubling of the main window costs ~808MiB of VRAM) and re-run setup; prefill goes slower when layers fall back to CPU"
      fi
    fi

    # Report the measured KV allocation rather than predicting it. Two caches
    # are listed per model on this architecture (q8_0 over the attention
    # layers, f16 over one more), so both lines are summed — and only the last
    # pair, since the log accumulates one set per model load.
    kvmib="$(server_log \
      | grep -oE 'llama_kv_cache: size = *[0-9]+\.[0-9]+ MiB \( *'"$NUM_CTX"' cells' \
      | tail -2 \
      | grep -oE '[0-9]+\.[0-9]+' \
      | awk '{ s += $1 } END { if (s > 0) printf "%.0f", s }' || true)"
    if [ -n "$kvmib" ]; then
      info "KV for $AGENT_MODEL at $NUM_CTX: ''${kvmib}MiB (~$((kvmib * 1024 / (NUM_CTX / 1024)))B/token)"
    fi
    info "RAM $(free -g 2>/dev/null | awk '/^Mem:/ { print $3"G used / "$2"G total, "$7"G available" }')"

    # Loaded models are ~27GB of a 30GB box here. With no swap configured,
    # running out means the OOM killer rather than a slowdown, so headroom is
    # worth a warning of its own.
    avail_mb="$(free -m 2>/dev/null | awk '/^Mem:/ { print $7 }')"
    swap_kb="$(free -k 2>/dev/null | awk '/^Swap:/ { print $2 }')"
    if [ -n "$avail_mb" ] && [ "$avail_mb" -lt 4096 ]; then
      meh "only ''${avail_mb}MB RAM available''${swap_kb:+ (swap: $((swap_kb / 1024))MB)}" \
        "lower AGENT_NUM_CTX, or set kvCacheType = \"q8_0\" — with no swap, exhausting RAM means an OOM kill"
    else
      info "RAM headroom ''${avail_mb:-?}MB, swap $((''${swap_kb:-0} / 1024))MB"
    fi

    # The performance cliff that "available RAM" does not predict. Most of
    # the 35B runs on CPU, so its ~22GB of weights have to stay in the page
    # cache; when they do not, prefill goes disk-bound. Measured: buff/cache
    # at 20GB gave ~151 tok/s prefill, at 13GB it collapsed to ~35 tok/s and
    # the first turn of a session stopped completing. Available RAM looked
    # fine (12GB) in both cases.
    cache_mb="$(free -m 2>/dev/null | awk '/^Mem:/ { print $6 }')"
    if model_resident "$AGENT_MODEL" && [ -n "$cache_mb" ] && [ "$cache_mb" -lt 18000 ]; then
      meh "page cache is only ''${cache_mb}MB but $AGENT_MODEL needs ~22GB of weights resident" \
        "lower AGENT_FAST_NUM_CTX — that KV lives in RAM at ~58KB/token and comes straight out of this cache (the main window's KV is in VRAM, so AGENT_NUM_CTX is not the lever here). Prefill goes disk-bound (~35 tok/s instead of ~151) when the weights fall out of cache"
    else
      info "page cache ''${cache_mb:-?}MB"
    fi

    say ""
    say "classifier timeouts"
    # Auto mode's safety classifier has its own ~60s budget, well under the
    # API_TIMEOUT_MS the agent sets for real turns. When those calls run on
    # the 35B — which is what happens unless CLAUDE_CODE_AUTO_MODE_MODEL
    # points at the small model — a cache-missing 27k-token prompt needs
    # minutes, so the client hangs up just short of the minute and ollama
    # logs the abort as a 500:
    #
    #   [GIN] | 500 | 59.997931977s | POST "/v1/messages?beta=true"
    #   srv  stop: cancel task, id_task = 389
    #
    # Agent-side this reads as "<model> is temporarily unavailable, so auto
    # mode cannot determine the safety of Bash".
    aborts="$(server_log | grep -cE '\| 500 \| +(59|6[0-5])\.' || true)"
    if [ "''${aborts:-0}" -gt 0 ]; then
      bad "$aborts request(s) aborted by the client at ~60s in the last hour" \
        "the agent must export CLAUDE_CODE_AUTO_MODE_MODEL=$FAST_MODEL (ANTHROPIC_SMALL_FAST_MODEL does not cover the auto-mode classifier) — update and re-run 'agent'"
    else
      ok "no ~60s client aborts in the last hour"
    fi

    say ""
    say "recent truncation"
    trunc="$(server_log \
      | grep -c 'truncating input prompt' || true)"
    if [ "''${trunc:-0}" -gt 0 ]; then
      # Name the model rather than guessing. The usable prompt is about
      # num_ctx/2, so the reported limit identifies which context was too
      # small — the two have very different fixes.
      last="$(server_log \
        | grep 'truncating input prompt' \
        | tail -1 \
        | grep -oE 'limit=[0-9]+ prompt=[0-9]+' || true)"
      lim="''${last#limit=}"
      lim="''${lim%% *}"

      which="unknown model"
      knob="AGENT_NUM_CTX"
      if [ -n "$lim" ] && [ "$lim" -le "$((FAST_NUM_CTX / 2 + 16))" ]; then
        which="$FAST_MODEL (side calls)"
        knob="AGENT_FAST_NUM_CTX"
      elif [ -n "$lim" ]; then
        which="$AGENT_MODEL"
      fi

      bad "ollama truncated $trunc prompt(s) in the last hour — $which, $last" \
        "raise $knob and re-run setup; if these predate a fix, they age out of the 1h window"
    else
      ok "no truncated prompts in the last hour"
    fi

    say ""
    say "hybrid mode"
    # All of this is informational when the router is down: plain 'agent'
    # talks to ollama directly and needs none of it.
    if ! router_up; then
      info "no router on $ROUTER_ADDR — only needed by hybrid-agent"
    else
      ok "router reachable at $ROUTER_ADDR"

      # A router started with a different table is the failure worth
      # catching. It does not error: unrouted models just go to Anthropic, so
      # the "local" subagents quietly become billable Claude calls.
      routed="$(router_local_models)"
      for m in "$AGENT_MODEL" "$FAST_MODEL"; do
        if printf '%s\n' "$routed" | grep -Fx "$m" >/dev/null; then
          ok "routes $m to ollama"
        else
          bad "the router does not route '$m' to ollama" \
            "stop it and re-run hybrid-agent — requests for an unrouted model go to Anthropic and get billed, which is the cost hybrid mode exists to avoid"
        fi
      done

      # The router's own truncation warning. Claude Code cannot bound a local
      # subagent's prompt in hybrid mode, because CLAUDE_CODE_MAX_CONTEXT_TOKENS
      # has to describe the Claude window there.
      rlog="$(cache_dir)/router.log"
      overruns="$(grep -c 'WARNING: .* will truncate it silently' "$rlog" 2>/dev/null || true)"
      if [ "''${overruns:-0}" -gt 0 ]; then
        meh "$overruns local request(s) exceeded the model window — see $rlog" \
          "the subagent read too much; tighten its scope or raise AGENT_NUM_CTX. Ollama truncated those prompts and said so only in its own log"
      else
        info "no local-prompt overruns recorded"
      fi
    fi

    # Model drift in the subagent definitions. A stale name here is silent in
    # exactly the same way: Claude Code honours the frontmatter verbatim, the
    # router does not recognise it, and the agent runs on Claude's bill.
    root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    shopt -s nullglob
    defs=("$root"/.claude/agents/local-*.md)
    shopt -u nullglob
    if [ "''${#defs[@]}" -eq 0 ]; then
      info "no .claude/agents/local-*.md in $root — hybrid mode has nothing to offload to"
    else
      for def in "''${defs[@]}"; do
        want="$(grep -m1 '^model:' "$def" | sed 's/^model:[[:space:]]*//' || true)"
        if [ "$want" = "$AGENT_MODEL" ]; then
          ok "$(basename "$def") -> $want"
        else
          bad "$(basename "$def") says model ''${want:-unset}, expected $AGENT_MODEL" \
            "edit the frontmatter to match agentModel in nix/settings.nix — an unrouted name silently runs this agent on Claude instead"
        fi
      done
    fi

    ulog="$(cache_dir)/router-usage.jsonl"
    if [ -s "$ulog" ]; then
      info "$(wc -l <"$ulog") router request(s) recorded — run local-ai-usage for the token split"
    fi

    say ""
    if [ "$fails" -gt 0 ]; then
      say "$fails failure(s), $warns warning(s)"
      exit 1
    fi
    say "healthy ($warns warning(s))"
  '';
}
