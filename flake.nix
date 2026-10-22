{
  description = "Local agentic development: Claude Code driven by a local Ollama model";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";

      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };

      settings = import ./nix/settings.nix;

      mkScript = import ./nix/mk-script.nix { inherit pkgs settings; };

      agent = import ./nix/agent.nix { inherit mkScript pkgs; };
      router = import ./nix/router.nix { inherit pkgs settings; };
      hybrid = import ./nix/hybrid.nix {
        inherit
          mkScript
          pkgs
          router
          settings
          ;
      };
      setup = import ./nix/setup.nix { inherit mkScript; };
      doctor = import ./nix/doctor.nix { inherit mkScript pkgs; };
      bench = import ./nix/bench.nix { inherit mkScript; };
      usage = import ./nix/usage.nix { inherit mkScript; };

      allScripts = [
        agent
        hybrid
        setup
        doctor
        bench
        usage
      ];

      # The router is a python derivation rather than an mkScript one, so it
      # is not in allScripts (which the nixos module iterates for shell
      # applications) but still has to land on PATH wherever the scripts do.
      allPackages = allScripts ++ [ router ];
    in
    {
      packages.${system} = {
        default = agent;
        inherit
          agent
          hybrid
          router
          setup
          doctor
          bench
          usage
          ;
        ollama = pkgs.ollama-cuda;
      };

      apps.${system} = {
        default = {
          type = "app";
          program = "${agent}/bin/agent";
          meta.description = "Start Claude Code on the local model";
        };
        setup = {
          type = "app";
          program = "${setup}/bin/local-ai-setup";
          meta.description = "Pull and build the local models (run once)";
        };
        doctor = {
          type = "app";
          program = "${doctor}/bin/local-ai-doctor";
          meta.description = "Diagnose context, eviction and cache settings";
        };
        bench = {
          type = "app";
          program = "${bench}/bin/local-ai-bench";
          meta.description = "Measure prefill, cached prefill and generation";
        };
        hybrid = {
          type = "app";
          program = "${hybrid}/bin/hybrid-agent";
          meta.description = "Start Claude Code on Claude, with local subagents";
        };
        router = {
          type = "app";
          program = "${router}/bin/local-ai-router";
          meta.description = "Run the model-dispatch router on its own";
        };
        usage = {
          type = "app";
          program = "${usage}/bin/local-ai-usage";
          meta.description = "Report the local-vs-remote token split";
        };
      };

      nixosModules.default = import ./nix/nixos-module.nix {
        agentPackages = allPackages;
        inherit settings;
      };

      formatter.${system} = pkgs.nixfmt-tree;

      checks.${system} = {
        inherit
          agent
          hybrid
          router
          setup
          doctor
          bench
          usage
          ;

        lint =
          pkgs.runCommand "lint"
            {
              nativeBuildInputs = [
                pkgs.statix
                pkgs.deadnix
              ];
            }
            ''
              cd ${self}
              statix check .
              deadnix --fail .
              touch $out
            '';
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = allPackages ++ [
          pkgs.ollama-cuda
          pkgs.claude-code
          pkgs.git
          pkgs.ripgrep
          pkgs.statix
          pkgs.deadnix
        ];

        shellHook = ''
          echo "local-ai-agent"
          echo "  local-ai-setup   pull + build models (run once)"
          echo "  local-ai-doctor  check context, eviction, cache settings"
          echo "  local-ai-bench   measure prefill and generation"
          echo "  local-ai-usage   local-vs-remote token split (hybrid mode)"
          echo "  agent            start Claude Code on ${settings.agentModel} (all local, free, slow)"
          echo "  hybrid-agent     start Claude Code on ${settings.hybrid.remoteMainModel}, with"
          echo "                   ${settings.agentModel} subagents for the read-heavy work"
          echo ""
          echo "  context ${settings.defaultNumCtx} (override with AGENT_NUM_CTX)"
        '';
      };
    };
}
