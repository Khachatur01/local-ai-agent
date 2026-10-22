# Declarative server settings for local agentic development.
#
# These are not cosmetic tuning. The measured cost of losing the prefix cache
# on this hardware is a ~3 minute re-prefill of a 27k-token prompt versus ~5
# seconds when it survives, so the defaults ollama ships with (5 minute idle
# eviction) dominate the experience.
#
# This module owns services.ollama rather than merely decorating it. An
# earlier version only merged environment variables and asserted that ollama
# was enabled elsewhere, which split one working configuration across two
# repositories: dropping services.ollama from the host config took the server
# away mid-session (ConnectionRefused), and enabling ollama without this
# module left a server running every default this file exists to override.
{ agentPackages, settings }:

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.local-ai-agent;
  env = settings.serverEnv;
in
{
  options.services.local-ai-agent = {
    enable = lib.mkEnableOption ''
      a cache-preserving ollama server for local agentic development.

      Enables services.ollama and sets its environment so a large prompt's KV
      cache survives between turns and the agent and classifier models stay
      resident together.
    '';

    ollamaPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.ollama;
      defaultText = lib.literalExpression "pkgs.ollama";
      example = lib.literalExpression "pkgs.ollama-cuda";
      description = ''
        Which ollama build to serve. The CPU default works; on a CUDA box use
        pkgs.ollama-cuda so the 35B can offload what fits in VRAM.

        Set with mkDefault, so a host that configures services.ollama.package
        itself still wins.
      '';
    };

    keepAlive = lib.mkOption {
      type = lib.types.str;
      default = env.OLLAMA_KEEP_ALIVE;
      example = "-1";
      description = ''
        How long ollama keeps an idle model loaded (OLLAMA_KEEP_ALIVE).

        The default of 5 minutes evicts the model between turns, discarding
        the prefix cache; the next turn then re-prefills the whole prompt.
        Use "-1" to never unload.
      '';
    };

    kvCacheType = lib.mkOption {
      type = lib.types.enum [
        "f16"
        "q8_0"
        "q4_0"
      ];
      default = env.OLLAMA_KV_CACHE_TYPE;
      description = ''
        KV cache quantization (OLLAMA_KV_CACHE_TYPE). q8_0 roughly halves KV
        memory versus f16, buying context headroom on a memory-bound machine.
        Requires flash attention, which this module also enables.
      '';
    };

    maxLoadedModels = lib.mkOption {
      type = lib.types.ints.positive;
      default = lib.toInt env.OLLAMA_MAX_LOADED_MODELS;
      description = ''
        How many models may stay resident (OLLAMA_MAX_LOADED_MODELS). Needs
        to be at least 2 so the agent model and the small classifier model
        used for Claude Code's side calls coexist instead of evicting each
        other.

        Leaving it unset is not equivalent: ollama then decides by memory
        fitting, and the 35B wins every time — the runner count drops back to
        1 and the classifier model is gone.
      '';
    };

    installAgent = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install the agent/setup/doctor/bench commands system-wide.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        # enable below is mkDefault, so an explicit services.ollama.enable =
        # false would quietly win and leave nothing listening on 11434.
        assertion = config.services.ollama.enable;
        message = ''
          services.local-ai-agent.enable = true needs the ollama server, but
          services.ollama.enable is set to false elsewhere in this
          configuration.
        '';
      }
      {
        assertion = cfg.maxLoadedModels >= 2;
        message = ''
          services.local-ai-agent.maxLoadedModels must be at least 2: the
          agent model and the classifier model have to stay resident
          together, or Claude Code's auto-mode safety checks queue behind a
          CPU-bound 35B inference and time out.
        '';
      }
    ];

    services.ollama = {
      enable = lib.mkDefault true;
      package = lib.mkDefault cfg.ollamaPackage;

      environmentVariables = {
        OLLAMA_KEEP_ALIVE = cfg.keepAlive;
        OLLAMA_MAX_LOADED_MODELS = toString cfg.maxLoadedModels;
        OLLAMA_KV_CACHE_TYPE = cfg.kvCacheType;

        # Neither of these is worth an option. Flash attention is the
        # prerequisite for the KV quantization above, and NUM_PARALLEL is
        # deliberately 1: each parallel slot allocates its own KV cache, so
        # raising it multiplies the ~23GB footprint rather than improving
        # throughput for a single-user agent.
        inherit (env) OLLAMA_FLASH_ATTENTION OLLAMA_NUM_PARALLEL;
      };
    };

    environment.systemPackages = lib.mkIf cfg.installAgent agentPackages;
  };
}
