# What hybrid mode actually saved, from the router's own log.
#
# The point of a number here is that the saving is otherwise invisible: the
# tokens a local subagent consumed never appear in any Claude Code UI, and
# neither does the much larger transcript they kept out of the main context.
# One JSONL line per request, written by nix/router.py.
{ mkScript }:

mkScript {
  name = "local-ai-usage";

  text = ''
    log="''${ROUTER_USAGE_LOG:-$(cache_dir)/router-usage.jsonl}"

    if [ ! -s "$log" ]; then
      say "no router traffic recorded yet ($log)"
      say "run 'hybrid-agent' — plain 'agent' talks to ollama directly and"
      say "never passes through the router, so it records nothing here."
      exit 0
    fi

    say "local-ai-usage — $log"
    say ""

    # No jq dependency, in keeping with the rest of this flake. Each key is
    # matched with its opening quote, which is what keeps "ts" from also
    # matching inside "status".
    awk '
      function num(line, key,   s) {
        if (match(line, "\"" key "\": *-?[0-9]+")) {
          s = substr(line, RSTART, RLENGTH)
          sub(/^[^:]*: */, "", s)
          return s + 0
        }
        return 0
      }
      function str(line, key,   s) {
        if (match(line, "\"" key "\": *\"[^\"]*\"")) {
          s = substr(line, RSTART, RLENGTH)
          sub(/^[^:]*: *"/, "", s)
          sub(/"$/, "", s)
          return s
        }
        return "-"
      }
      function commify(n,   s, out) {
        s = sprintf("%d", n)
        while (length(s) > 3) {
          out = "," substr(s, length(s) - 2) out
          s = substr(s, 1, length(s) - 3)
        }
        return s out
      }

      {
        up = str($0, "upstream")
        m = str($0, "model")
        calls[up]++
        mcalls[up "\t" m]++
        for (f = 1; f <= 4; f++) {
          k = (f == 1 ? "in" : (f == 2 ? "cache_read" : (f == 3 ? "cache_write" : "out")))
          v = num($0, k)
          tot[up "\t" k] += v
          mtot[up "\t" m "\t" k] += v
          if (f != 4) prompt[up] += v
          else output[up] += v
        }
        ms[up] += num($0, "ms")
        if (num($0, "status") >= 400) errs[up]++
        seen[up] = 1
        models[up "\t" m] = 1
      }

      END {
        printf "%-10s %7s %12s %12s %12s %12s %9s\n", \
          "upstream", "calls", "input", "cache rd", "cache wr", "output", "errors"
        for (up in seen) {
          printf "%-10s %7d %12s %12s %12s %12s %9d\n", up, calls[up], \
            commify(tot[up "\tin"]), commify(tot[up "\tcache_read"]), \
            commify(tot[up "\tcache_write"]), commify(tot[up "\tout"]), \
            errs[up] + 0
        }

        print ""
        print "by model"
        for (key in models) {
          split(key, p, "\t")
          up = p[1]; m = p[2]
          printf "  %-10s %-30s %6d calls  %12s prompt  %10s out  %6.1fs avg\n", \
            up, m, mcalls[key], \
            commify(mtot[key "\tin"] + mtot[key "\tcache_read"] + mtot[key "\tcache_write"]), \
            commify(mtot[key "\tout"]), \
            (mcalls[key] ? (ms[up] / calls[up]) / 1000 : 0)
        }

        # The headline. Prompt tokens are the ones that dominate: they are
        # re-sent on every turn, which is why keeping tool-result bulk out of
        # the main transcript is worth more than it first appears.
        local_p = prompt["ollama"] + 0
        remote_p = prompt["anthropic"] + 0
        total_p = local_p + remote_p
        print ""
        if (total_p > 0) {
          printf "prompt tokens: %s local, %s remote — %.1f%% served on this machine\n", \
            commify(local_p), commify(remote_p), 100 * local_p / total_p
        }
        local_o = output["ollama"] + 0
        remote_o = output["anthropic"] + 0
        if (local_o + remote_o > 0) {
          printf "output tokens: %s local, %s remote — %.1f%% served on this machine\n", \
            commify(local_o), commify(remote_o), \
            100 * local_o / (local_o + remote_o)
        }
      }
    ' "$log"

    say ""
    say "note: this counts only what crossed the router. The larger saving is"
    say "the tool output a local subagent read and never put in the main"
    say "transcript, which by design was never sent anywhere."
  '';
}
