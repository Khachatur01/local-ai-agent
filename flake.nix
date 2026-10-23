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

        configDir = "\${XDG_CONFIG_HOME:-$HOME/.config}/opencode-local";

        # Default OpenCode config for Ollama
        defaultConfig = pkgs.writeText "opencode.json" (builtins.toJSON {
          "$schema" = "https://opencode.ai/config.json";
          provider = {
            ollama = {
              npm = "@ai-sdk/openai-compatible";
              name = "Ollama (local)";
              options = {
                baseURL = "http://localhost:11434/v1";
              };
              models = {
                "qwen2.5-coder:7b" = { name = "Qwen 2.5 Coder 7B"; };
                "qwen2.5-coder:14b" = { name = "Qwen 2.5 Coder 14B"; };
                "deepseek-coder-v2:16b" = { name = "DeepSeek Coder V2 16B"; };
                "codellama:13b" = { name = "Code Llama 13B"; };
                "qwen3.6:35b-a3b" = { name = "Qwen 3.6 Coder 35B"; };
              };
            };
          };
        });

        # Script to ensure Ollama is running
        ensureOllama = pkgs.writeShellScript "ensure-ollama" ''
          if ! ${pkgs.ollama}/bin/ollama list &>/dev/null; then
            echo "Starting Ollama server..."
            ${pkgs.ollama}/bin/ollama serve &
            sleep 2
          fi
        '';

        # Main wrapper that sets up config and launches OpenCode
        opencode-local = pkgs.writeShellApplication {
          name = "opencode-local";
          runtimeInputs = [ pkgs.opencode pkgs.ollama ];
          text = ''
            # Ensure config directory exists
            mkdir -p "${configDir}"

            # Copy default config if none exists
            if [ ! -f "${configDir}/opencode.json" ]; then
              cp ${defaultConfig} "${configDir}/opencode.json"
              chmod 644 "${configDir}/opencode.json"
              echo "Created default config at ${configDir}/opencode.json"
            fi

            # Ensure Ollama is running
            ${ensureOllama}

            # Check if a model is available
            if ! ollama list | grep -q "qwen2.5-coder"; then
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

            case "''${1:-small}" in
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
                echo "  small  - qwen2.5-coder:7b"
                echo "  medium - qwen2.5-coder:14b"
                echo "  large  - qwen3.6:35b-a3b"
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
          default = opencode-local;
        };

        devShells.default = pkgs.mkShell {
          buildInputs = [ pkgs.opencode pkgs.ollama ];
          shellHook = ''
            echo "OpenCode + Ollama development shell"
            echo ""
            echo "Commands:"
            echo "  ollama serve     - Start Ollama server"
            echo "  ollama pull ...  - Download a model"
            echo "  opencode         - Start OpenCode"
          '';
        };
      });
}
