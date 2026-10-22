# Builds a shell application with the settings prelude and shared helpers
# already in scope, so agent/setup/doctor/bench cannot disagree about which
# models they are talking about.
{ pkgs, settings }:

{
  name,
  runtimeInputs ? [ ],
  text,
}:

let
  # The server settings as ready-to-use "KEY=value" words for the SERVER_ENV
  # array in the prelude below.
  serverEnvArgs = pkgs.lib.concatStringsSep " " (
    pkgs.lib.mapAttrsToList (k: v: ''"${k}=${v}"'') settings.serverEnv
  );
in
pkgs.writeShellApplication {
  inherit name;

  runtimeInputs = [
    pkgs.ollama-cuda
    pkgs.curl
    pkgs.coreutils
    pkgs.gnugrep
    pkgs.gawk

    # common.sh: sed in server_env, systemctl in systemd_managed, pgrep to
    # find a server this user started.
    pkgs.gnused
    pkgs.systemd
    pkgs.procps
  ]
  ++ runtimeInputs;

  # The prelude exports rather than assigns: it keeps shellcheck from
  # reporting every value a given script happens not to use (SC2034).
  text = ''
    export BASE_MODEL="${settings.baseModel}"
    export AGENT_MODEL="${settings.agentModel}"
    export NUM_CTX="''${AGENT_NUM_CTX:-${settings.defaultNumCtx}}"
    export FAST_BASE_MODEL="${settings.fastBaseModel}"
    export FAST_MODEL="${settings.fastModel}"
    export FAST_NUM_CTX="''${AGENT_FAST_NUM_CTX:-${settings.fastNumCtx}}"
    export AGENT_NUM_GPU="${settings.agentNumGpu}"
    export FAST_NUM_GPU="${settings.fastNumGpu}"
    export OLLAMA_ADDR="''${OLLAMA_HOST:-127.0.0.1:11434}"
    export API="http://$OLLAMA_ADDR"

    # The server settings ensure_server has to pass on when it starts ollama
    # itself. Not exported: an array cannot be, and common.sh is sourced into
    # the same shell anyway.
    #
    # shellcheck disable=SC2034  # read by ensure_server in common.sh
    SERVER_ENV=( ${serverEnvArgs} )

    # shellcheck source=/dev/null
    source ${./common.sh}

    ${text}
  '';
}
