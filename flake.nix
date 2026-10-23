
{
  description = "Local AI coding assistant with OpenCode and Ollama";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

        # NVIDIA CUDA-enabled Ollama
        ollama = pkgs.ollama-cuda;

        # Recommended model bundles
        recommendedModels = [
          "qwen2.5-coder:7b"
          "qwen2.5-coder:14b"
          "deepseek-coder-v2:16b"
          "codellama:13b"
          "qwen3.6:35b-a3b"
        ];

        # Friendly display names for local models
        friendlyNames = {
          "qwen2.5-coder:7b"      = "Qwen 2.5 Coder 7B";
          "qwen2.5-coder:14b"     = "Qwen 2.5 Coder 14B";
          "deepseek-coder-v2:16b" = "DeepSeek Coder V2 16B";
          "codellama:13b"         = "Code Llama 13B";
          "qwen3.6:35b-a3b"       = "Qwen 3.6 Coder 35B";
        };

        # Resolve XDG_CONFIG_HOME at runtime in the shell
        configDir = "\${XDG_CONFIG_HOME:-$HOME/.config}/opencode-local";

        # OpenCode model list
        modelList = pkgs.lib.mapAttrsToList (name: displayName: {
          inherit name displayName;
        }) friendlyNames;

        # Default OpenCode configuration for Ollama
        defaultConfig = pkgs.writeText "opencode.json" (builtins.toJSON {
          "$schema" = "https://opencode.ai/config.json";

          provider = {
            ollama = {
              name = "Ollama (local)";
              npm = "@ai-sdk/openai-compatible";

              options = {
                baseURL = "http://localhost:11434/v1";
                modelList = modelList;
              };
            };
          };
        });

        # Ensure Ollama is running
        ensureOllama = pkgs.writeShellScript "ensure-ollama" ''
          if ! ${ollama}/bin/ollama list &>/dev/null; then
            echo "Starting Ollama server..."

            mkdir -p "$HOME/.local/share/opencode-local"

            ${ollama}/bin/ollama serve \
              >> "$HOME/.local/share/opencode-local/ollama.log" 2>&1 &

            disown
          fi
        '';

        # Main OpenCode wrapper
        opencode-local = pkgs.writeShellApplication {
          name = "opencode-local";

          runtimeInputs = [
            pkgs.opencode
            ollama
            pkgs.coreutils
            pkgs.gnugrep
          ];

          text = ''
            # Ensure directories exist
            mkdir -p "${configDir}"
            mkdir -p "$HOME/.local/share/opencode-local"

            # Create default config if it doesn't exist
            if [ ! -f "${configDir}/opencode.json" ]; then
              cp ${defaultConfig} "${configDir}/opencode.json"
              chmod 644 "${configDir}/opencode.json"

              echo "Created default config at ${configDir}/opencode.json"
            fi

            # Ensure Ollama is running
            ${ensureOllama}

            # Check whether a recommended model is available
            found=false

            for m in ${builtins.concatStringsSep " " recommendedModels}; do
              if ollama list | grep -Fq "''${m}"; then
                echo "Found model: $m"
                found=true
                break
              fi
            done

            if [ "$found" = "false" ]; then
              echo ""
              echo "No recommended coding model found."
              echo "Pull one with: ollama pull qwen2.5-coder:7b"
              echo ""
              echo "Starting OpenCode anyway..."
            fi

            # Launch OpenCode
            export OPENCODE_CONFIG="${configDir}/opencode.json"
            exec opencode "$@"
          '';
        };

        # Helper to pull recommended models
        pull-models = pkgs.writeShellApplication {
          name = "pull-models";

          runtimeInputs = [
            ollama
            pkgs.coreutils
          ];

          text = ''
            echo "Pulling recommended coding models..."
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
                echo "  medium - qwen2.5-coder:14b + deepseek-coder-v2:16b"
                echo "  large  - qwen3.6:35b-a3b"
                exit 1
                ;;
            esac

            echo ""
            echo "Done! Models are cached in Ollama's model directory."
          '';
        };

        # Bundle wrappers and Ollama
        opencode-nix = pkgs.symlinkJoin {
          name = "opencode-nix";

          paths = [
            opencode-local
            pull-models
            ollama
          ];
        };

      in
      {
        packages = {
          inherit opencode-local pull-models opencode-nix;
          default = opencode-local;
        };

        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.opencode
            ollama
          ];

          shellHook = ''
            echo "OpenCode + Ollama (NVIDIA CUDA)"
            echo ""
            echo "Commands:"
            echo "  ollama serve       - Start Ollama server"
            echo "  ollama pull MODEL  - Download a model"
            echo "  ollama ps          - Check CPU/GPU model placement"
            echo "  opencode           - Start OpenCode"
            echo ""
            echo "Helpers:"
            echo "  nix run .#opencode-local"
            echo "  nix run .#pull-models -- small"
            echo "  nix run .#pull-models -- medium"
            echo "  nix run .#pull-models -- large"
          '';
        };
      });
}
