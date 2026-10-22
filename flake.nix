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
      setup = import ./nix/setup.nix { inherit mkScript; };
      doctor = import ./nix/doctor.nix { inherit mkScript; };
      bench = import ./nix/bench.nix { inherit mkScript; };

      allScripts = [
        agent
        setup
        doctor
        bench
      ];
    in
    {
      packages.${system} = {
        default = agent;
        inherit
          agent
          setup
          doctor
          bench
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
      };

      nixosModules.default = import ./nix/nixos-module.nix {
        agentPackages = allScripts;
        inherit settings;
      };

      formatter.${system} = pkgs.nixfmt-tree;

      checks.${system} = {
        inherit
          agent
          setup
          doctor
          bench
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
        packages = allScripts ++ [
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
          echo "  agent            start Claude Code on ${settings.agentModel}"
          echo ""
          echo "  context ${settings.defaultNumCtx} (override with AGENT_NUM_CTX)"
        '';
      };
    };
}
