# Measures the three numbers that decide whether this setup is usable:
# cold prefill, cached prefill, and generation.
#
# The gap between cold and cached prefill is the whole story — on this box it
# was 176.6s vs 5.1s for the same 27k prompt, which is why the configuration
# is built around not losing the KV cache.
{ mkScript }:

mkScript {
  name = "local-ai-bench";

  text = ''
    model="''${1:-$AGENT_MODEL}"
    tokens="''${BENCH_PROMPT_TOKENS:-27000}"

    ensure_server

    if ! have_model "$model"; then
      die "model '$model' not found — run: nix run .#setup"
    fi

    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT

    # Unique random text, so the server cannot serve this from a cache left
    # over by a previous run. ~4 chars per token is close enough for sizing.
    #
    # head reads /dev/urandom directly rather than sitting downstream of od:
    # as the last stage of a pipe it would exit early, SIGPIPE od, and
    # pipefail would make that fatal (exit 141). Trimming to the target width
    # happens with cut on a file for the same reason.
    head -c "$((tokens * 2))" /dev/urandom \
      | od -An -x \
      | tr -d '\042\134' \
      | tr -s ' \n' ' ' >"$work/filler.raw"
    cut -c "1-$((tokens * 4))" "$work/filler.raw" >"$work/filler"

    mk_request() {
      {
        printf '{"model":"%s","stream":false,"think":false,' "$model"
        printf '"options":{"num_predict":%s},"prompt":"%s ' "$1" "$2"
        # Newlines must not survive into the JSON string literal.
        tr -d '\n' <"$work/filler"
        printf '"}'
      } >"$work/req.json"
    }

    run_request() {
      curl -s -m 900 "$API/api/generate" \
        -H 'content-type: application/json' \
        --data-binary @"$work/req.json"
    }

    # tok/s from nanosecond durations, 1 decimal place, without bc.
    rate() {
      awk -v c="$1" -v ns="$2" 'BEGIN {
        if (ns > 0) printf "%.1f", c / (ns / 1000000000); else printf "n/a"
      }'
    }

    report() {
      local label="$1" json="$2" count_key="$3" dur_key="$4"
      local c d
      c="$(json_num "$json" "$count_key")"
      d="$(json_num "$json" "$dur_key")"
      if [ -z "$c" ] || [ -z "$d" ]; then
        say "  $label: no data (is the model loaded?)"
        return
      fi
      printf '  %-22s %7s tok  %8s s  %9s tok/s\n' \
        "$label" "$c" "$(awk -v d="$d" 'BEGIN { printf "%.1f", d / 1000000000 }')" \
        "$(rate "$c" "$d")"
    }

    say "model: $model   target prompt: ~$tokens tokens"
    say ""

    say "unloading to force a cold measurement"
    ollama stop "$model" >/dev/null 2>&1 || true

    say "pass 1 — cold prefill (model load + full prompt)"
    mk_request 1 "Summarize:"
    cold="$(run_request)"
    report "cold prefill" "$cold" prompt_eval_count prompt_eval_duration

    say ""
    say "pass 2 — cached prefill (identical prompt, now in the KV cache)"
    warm="$(run_request)"
    report "cached prefill" "$warm" prompt_eval_count prompt_eval_duration

    say ""
    say "pass 3 — generation"
    mk_request 128 "Summarize:"
    gen="$(run_request)"
    report "generation" "$gen" eval_count eval_duration

    say ""
    cold_ns="$(json_num "$cold" prompt_eval_duration)"
    warm_ns="$(json_num "$warm" prompt_eval_duration)"
    if [ -n "$cold_ns" ] && [ -n "$warm_ns" ] && [ "$warm_ns" -gt 0 ]; then
      say "cache speedup: $(awk -v a="$cold_ns" -v b="$warm_ns" \
        'BEGIN { printf "%.0fx", a / b }') on prefill"
      say ""
      say "That multiple is what OLLAMA_KEEP_ALIVE protects. If the model is"
      say "evicted between turns, every turn pays the cold number."
    fi
  '';
}
