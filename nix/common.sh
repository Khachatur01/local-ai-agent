# shellcheck shell=bash
#
# Shared helpers for agent/setup/doctor/bench. Sourced, never executed.
#
# Callers are expected to have already set: API, BASE_MODEL, AGENT_MODEL,
# NUM_CTX, FAST_BASE_MODEL, FAST_MODEL, FAST_NUM_CTX, AGENT_NUM_GPU,
# FAST_NUM_GPU.

say() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die() {
  warn "$*"
  exit 1
}

server_up() {
  curl -sf -m 2 "$API/api/version" >/dev/null 2>&1
}

# True when ollama runs under systemd, as opposed to a server started by
# ensure_server or by hand.
systemd_managed() {
  systemctl cat ollama >/dev/null 2>&1
}

# Value of one variable as the running server actually sees it.
#
# Two sources, because there are two ways the server gets started: the ollama
# unit's Environment= when it is systemd-managed, and /proc otherwise — a
# server started by this user is readable there.
#
# The "|| true" on each pipeline is required twice over: an unset variable
# makes grep exit 1, and head closing the pipe SIGPIPEs grep. Either would
# abort the caller under errexit+pipefail on exactly the condition it is
# asking about.
server_env() {
  local val
  val="$(
    systemctl show ollama -p Environment 2>/dev/null \
      | sed 's/^Environment=//' \
      | tr ' ' '\n' \
      | grep -E "^$1=" \
      | head -1 \
      | cut -d= -f2- \
      || true
  )"
  if [ -n "$val" ]; then
    printf '%s\n' "$val"
    return 0
  fi

  local pid
  pid="$(pgrep -u "$(id -u)" -x ollama 2>/dev/null | head -1 || true)"
  if [ -n "$pid" ] && [ -r "/proc/$pid/environ" ]; then
    tr '\0' '\n' <"/proc/$pid/environ" \
      | grep -E "^$1=" \
      | head -1 \
      | cut -d= -f2- \
      || true
  fi
}

# Start a server only if nothing is already listening, so we reuse the NixOS
# services.ollama unit when it is running.
ensure_server() {
  if server_up; then
    return 0
  fi

  local log_dir="${XDG_CACHE_HOME:-$HOME/.cache}/local-ai-agent"
  local log="$log_dir/ollama.log"
  mkdir -p "$log_dir"
  # The settings in SERVER_ENV have to be passed explicitly. A server started
  # here inherits nothing from services.ollama, and the defaults it would
  # otherwise run with are the ones that produce every symptom this project
  # exists to avoid: 5m keep-alive (cold prefill every turn) and unbounded
  # max-loaded (the 35B evicts the classifier model).
  say "starting ollama (log: $log)"
  warn "note: not systemd-managed; applying the local-ai-agent settings inline"
  nohup env "${SERVER_ENV[@]}" ollama serve >"$log" 2>&1 </dev/null &

  local i
  for i in $(seq 1 60); do
    if server_up; then
      return 0
    fi
    sleep 1
  done

  die "ollama did not come up; see $log"
}

# No -q on grep: -q exits on first match, which SIGPIPEs the upstream
# ollama/awk and makes pipefail report failure even though the model was
# found.
#
# Both spellings are matched because `ollama list` prints an explicit tag:
# models created without one show up as "name:latest".
have_model() {
  ollama list \
    | awk 'NR > 1 { print $1 }' \
    | grep -Fx -e "$1" -e "$1:latest" >/dev/null
}

# model_param <model> <param> — empty if the model or param is absent.
#
# The trailing "|| true" matters: when the derived model does not exist yet
# ollama show fails, and a failing command substitution in a bare assignment
# aborts the whole script under errexit.
model_param() {
  local params
  params="$(ollama show "$1" --parameters 2>/dev/null || true)"
  printf '%s\n' "$params" | awk -v k="$2" '$1 == k { print $2 }'
}

# ensure_model <derived> <base> <num_ctx> <num_gpu|""> <download note>
#
# num_gpu is the number of layers to offload: "" lets ollama decide, 0 forces
# CPU. Rebuilds whenever either baked-in value drifts from what we want.
ensure_model() {
  local derived="$1" base="$2" ctx="$3" gpu="$4" note="$5"

  if ! have_model "$base"; then
    say "pulling $base ($note)"
    ollama pull "$base"
  fi

  local current_ctx current_gpu
  current_ctx="$(model_param "$derived" num_ctx)"
  current_gpu="$(model_param "$derived" num_gpu)"

  if [ "$current_ctx" = "$ctx" ] && [ "$current_gpu" = "$gpu" ]; then
    say "ok    $derived (num_ctx=$ctx num_gpu=${gpu:-auto})"
    return 0
  fi

  say "build $derived (num_ctx=$ctx num_gpu=${gpu:-auto})"
  local work
  work="$(mktemp -d)"
  {
    printf 'FROM %s\n' "$base"
    printf 'PARAMETER num_ctx %s\n' "$ctx"
    if [ -n "$gpu" ]; then
      printf 'PARAMETER num_gpu %s\n' "$gpu"
    fi
  } >"$work/Modelfile"
  ollama create "$derived" -f "$work/Modelfile" >/dev/null
  rm -rf "$work"
}

# Verify without mutating, so `agent` starts fast and stays side-effect free.
require_model() {
  local derived="$1" ctx="$2" gpu="$3"

  if ! have_model "$derived"; then
    die "missing model '$derived' — run: nix run .#setup"
  fi

  local current_ctx current_gpu
  current_ctx="$(model_param "$derived" num_ctx)"
  current_gpu="$(model_param "$derived" num_gpu)"

  if [ "$current_ctx" != "$ctx" ] || [ "$current_gpu" != "$gpu" ]; then
    die "model '$derived' has num_ctx=${current_ctx:-unset} num_gpu=${current_gpu:-auto}, expected num_ctx=$ctx num_gpu=${gpu:-auto} — run: nix run .#setup"
  fi
}

# Field of `ollama ps` for a loaded model; empty when not resident.
# Matches on the bare name since ps prints "name:latest".
ps_field() {
  ollama ps | awk -v m="$1" -v c="$2" '
    NR > 1 && ($1 == m || $1 == m ":latest") { print $c }
  '
}

model_resident() { [ -n "$(ps_field "$1" 1)" ]; }

# Load a model and ask the server to hold it. keep_alive only holds until
# Claude Code's own (unset) keep_alive resets it to the server default, so
# this is a head start, not a guarantee — OLLAMA_KEEP_ALIVE is the real fix.
warm_model() {
  curl -sf -m "${2:-120}" "$API/api/generate" \
    -H 'content-type: application/json' \
    -d "{\"model\":\"$1\",\"keep_alive\":\"24h\"}" >/dev/null 2>&1
}

# Numeric JSON field, no jq dependency. Empty when absent — note the
# "|| true": a missing field makes grep exit 1, which pipefail would turn
# into an errexit abort inside the caller's command substitution.
json_num() {
  grep -oE "\"$2\":[0-9]+" <<<"$1" | head -1 | cut -d: -f2 || true
}
