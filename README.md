# opencode-nix

A Nix flake for running [OpenCode](https://github.com/sst/opencode) with local LLMs via [Ollama](https://ollama.com). Provides a Claude Code-like TUI coding assistant that works completely offline.

## Setup

```bash
# Pull a coding model (while online)
nix run github:Khachatur01/opencode-nix#pull-models -- small
nix run github:Khachatur01/opencode-nix#pull-models -- medium
nix run github:Khachatur01/opencode-nix#pull-models -- large

# Run OpenCode
nix run github:Khachatur01/opencode-nix
```

## Usage

```bash
# Start OpenCode (auto-starts Ollama if needed)
nix run github:Khachatur01/opencode-nix

# Enter a dev shell with opencode and ollama available
nix develop github:Khachatur01/opencode-nix
```

Config is created at `~/.config/opencode-local/opencode.json` on first run. Edit to add MCP servers or change models.
