# Packaging for the model-dispatch router. The logic is in nix/router.py.
#
# The defaults baked in here only make `local-ai-router` runnable on its own,
# which is what the doctor's routing check and any manual curl test need.
# hybrid-agent overrides ROUTER_LOCAL_MODELS and ROUTER_USAGE_LOG from its own
# settings prelude, so an AGENT_NUM_CTX override reaches the truncation guard
# instead of leaving it comparing against a stale window.
{ pkgs, settings }:

let
  # Stdlib only, deliberately: this process sits in the path of every API
  # call the agent makes, and a dependency here would be one more thing that
  # can break a session. flake8 runs as part of the build; E501 is ignored
  # because the comments explaining each failure mode are worth more than a
  # 79-column limit.
  server =
    pkgs.writers.writePython3Bin "local-ai-router-unwrapped"
      {
        libraries = [ ];
        flakeIgnore = [ "E501" ];
      }
      (builtins.readFile ./router.py);

  inherit (settings) hybrid;
  table = "${settings.agentModel}:${settings.defaultNumCtx},${settings.fastModel}:${settings.fastNumCtx}";
in
pkgs.runCommand "local-ai-router"
  {
    nativeBuildInputs = [ pkgs.makeWrapper ];
    meta.description = "Route Anthropic API calls to Anthropic or ollama by model name";
  }
  ''
    mkdir -p $out/bin
    makeWrapper ${server}/bin/local-ai-router-unwrapped \
      $out/bin/local-ai-router \
      --set-default ROUTER_ADDR ${hybrid.routerAddr} \
      --set-default ROUTER_REMOTE_API ${hybrid.remoteApi} \
      --set-default ROUTER_LOCAL_API http://127.0.0.1:11434 \
      --set-default ROUTER_LOCAL_MODELS ${table}
  ''
