# opencode-nix

A Nix flake for running [OpenCode](https://github.com/sst/opencode) with local LLMs via [Ollama](https://ollama.com). Provides a Claude Code-like TUI coding assistant that works completely offline.

## Setup

```bash
# Pull a coding model (requires internet)
nix run github:Khachatur01/opencode-nix#pull-models -- small   # qwen2.5-coder:7b
nix run github:Khachatur01/opencode-nix#pull-models -- medium  # qwen2.5-coder:14b + deepseek-coder-v2:16b
nix run github:Khachatur01/opencode-nix#pull-models -- large   # qwen3.6:35b-a3b

# Run OpenCode (auto-starts Ollama if needed)
nix run github:Khachatur01/opencode-nix
```

## Usage

```bash
# Start OpenCode (auto-starts Ollama if needed; works offline)
nix run github:Khachatur01/opencode-nix

# Enter a dev shell with opencode and ollama available
# Note: 'nix develop' requires internet on first use to fetch the derivation
nix develop github:Khachatur01/opencode-nix
```

Config is created at `~/.config/opencode-local/opencode.json` on first run. Edit to add MCP servers or change models.
