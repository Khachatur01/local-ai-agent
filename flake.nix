{
  description = "Local AI coding assistant with OpenCode and Ollama";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # Recommended model bundles - defined once, reused everywhere
        recommendedModels = [
          "qwen2.5-coder:7b"
          "qwen2.5-coder:14b"
          "deepseek-coder-v2:16b"
          "codellama:13b"
          "qwen3.6:35b-a3b"
        ];

        # Friendly display names for local models
        friendlyNames = {
          "qwen2.5-coder:7b"         = "Qwen 2.5 Coder 7B";
          "qwen2.5-coder:14b"        = "Qwen 2.5 Coder 14B";
          "deepseek-coder-v2:16b"    = "DeepSeek Coder V2 16B";
          "codellama:13b"            = "Code Llama 13B";
          "qwen3.6:35b-a3b"          = "Qwen 3.6 Coder 35B";
        };

        # Config data directory for Ollama logs  
        configDir = "\${XDG_CONFIG_HOME:-$HOME/.config}/opencode-local";

        # Build modelList from friendlyNames as JSON array of {name, displayName} objects
        modelList = builtins.mapAttrsToList (k: v: {
          inherit k;
          displayName = v;
        }) friendlyNames;

        # Default OpenCode config for Ollama
        defaultConfig = pkgs.writeText "opencode.json" (builtins.toJSON {
          "$schema" = "https://opencode.ai/config.json";
          provider = {
            ollama = {
              name  = "Ollama (local)";
              npm   = "@ai-sdk/openai-compatible";
              options = {
                baseURL   = "http://localhost:11434/v1";
                modelList = modelList;
              };
            };
          };
        });

        # Script to ensure Ollama is running, with proper logging and longer startup timeout
        ensureOllama = pkgs.writeShellScript "ensure-ollama" ''
          if ! ${pkgs.ollama}/bin/ollama list &>/dev/null; then
            echo "Starting Ollama server..."
            mkdir -p "$HOME/.local/share/opencode-local"
            ${pkgs.ollama}/bin/ollama serve >> "$HOME/.local/share/opencode-local/ollama.log" 2>&1 &
            disown
          fi
        '';

        # Main wrapper that sets up config and launches OpenCode
        opencode-local = pkgs.writeShellApplication {
          name = "opencode-local";
          runtimeInputs = [ pkgs.opencode pkgs.ollama ];
          text = ''
            # Ensure config directory exists
            mkdir -p "${configDir}"
            mkdir -p "$HOME/.local/share/opencode-local"

            # Copy default config if none exists
            if [ ! -f "${configDir}/opencode.json" ]; then
              cp ${defaultConfig} "${configDir}/opencode.json"
              chmod 644 "${configDir}/opencode.json"
              echo "Created default config at ${configDir}/opencode.json"
            fi

            # Ensure Ollama is running
            ${ensureOllama}

            # Check if a coding model is available (exact tag match)
            found=false
            for m in ${builtins.concatStringsSep " " recommendedModels}; do
              if ollama list | grep -q "^${m}\s"; then
                echo "Found model: $m"
                found=true; break
              fi
            done

            if [ "$found" = "false" ]; then
              echo ""
              echo "No coding model found. Pull one with:"
              echo "  ollama pull qwen2.5-coder:7b"
              echo ""
              echo "Starting OpenCode anyway..."
            fi

            # Launch OpenCode with our config
            OPENCODE_CONFIG="${configDir}/opencode.json" exec opencode "$@"
          '';
        };

        # Helper to pull recommended models
        pull-models = pkgs.writeShellApplication {
          name = "pull-models";
          runtimeInputs = [ pkgs.ollama ];
          text = ''
            echo "Pulling recommended coding models for offline use..."
            echo ""

            ${ensureOllama}

            case "${1:-small}" in
              small)
                echo "Pulling qwen2.5-coder:7b..."
                ollama pull qwen2.5-coder:7b
                ;;
              medium)
                echo "Pulling qwen2.5-coder:14b and deepseek-coder-v2:16b..."
                ollama pull qwen2.5-coder:14b
                ollama pull deepseek-coder-v2:16b
                ;;
              large)
                echo "Pulling qwen3.6:35b-a3b..."
                ollama pull qwen3.6:35b-a3b
                ;;
              *)
                echo "Usage: pull-models [small|medium|large]"
                echo ""
                echo "  small - qwen2.5-coder:7b"
                echo "  medium - qwen2.5-coder:14b + deepseek-coder-v2:16b"
                echo "  large - qwen3.6:35b-a3b"
                exit 1
                ;;
            esac

            echo ""
            echo "Done! Models are cached at ~/.ollama/models"
          '';
        };

        # Bundle everything together
        opencode-nix = pkgs.symlinkJoin {
          name = "opencode-nix";
          paths = [ opencode-local pull-models pkgs.ollama ];
        };

      in
      {
        packages = {
          inherit opencode-local pull-models opencode-nix;
          default   = opencode-local;
        };

        devShells.default = pkgs.mkShell {
          buildInputs = [ pkgs.opencode pkgs.ollama ];
          shellHook = ''
            echo "OpenCode + Ollama development shell"
            echo ""
            echo "WARNING: 'nix develop' requires internet to fetch missing derivations."
            echo "For offline work, use 'nix run github:Khachatur01/opencode-nix' instead."
            echo ""
            echo "Commands:"
            echo "  ollama serve - Start Ollama server"
            echo "  ollama pull ... - Download a model"
            echo "  opencode    - Start OpenCode"
          '';
        };
      });
}
