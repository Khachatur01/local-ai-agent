
{
  description = "Local AI coding agent with Ollama CUDA and Qwen3.6";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      projectName = builtins.baseNameOf (toString self);

      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };

      ollama = pkgs.ollama-cuda;
      model = "qwen3.6:35b-a3b";

      agent = pkgs.writeShellApplication {
        name = "agent";

        runtimeInputs = [
          ollama
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.gawk
        ];

        text = ''
          MODEL="${model}"
          PROJECT_NAME="${projectName}"
          OLLAMA_LOG="$HOME/.cache/$PROJECT_NAME/ollama.log"

          # Start Ollama if it is not already running.
          if ! ollama list >/dev/null 2>&1; then
            mkdir -p "$(dirname "$OLLAMA_LOG")"

            nohup ollama serve \
              >"$OLLAMA_LOG" 2>&1 \
              </dev/null &

            echo "Starting Ollama..."

            ready=0
            for _ in $(seq 1 60); do
              if ollama list >/dev/null 2>&1; then
                ready=1
                break
              fi
              sleep 1
            done

            if [ "$ready" -ne 1 ]; then
              echo "Ollama failed to start. Log: $OLLAMA_LOG" >&2
              exit 1
            fi
          fi

          # Download the model on first use.
          if ! ollama list |
            awk 'NR > 1 { print $1 }' |
            grep -Fxq "$MODEL"; then
            ollama pull "$MODEL"
          fi

          # Launch Claude Code using Ollama.
          exec ollama launch claude \
            --model "$MODEL" \
            --yes \
            -- "$@"
        '';
      };

    in {
      packages.${system} = {
        default = ollama;
        inherit agent;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          ollama
          agent
        ];

        shellHook = ''
          echo "Local AI agent environment: ${projectName}"
          echo "Run 'agent' to launch Claude Code with ${model}."
        '';
      };
    };
}
