# aidock

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![CI](https://github.com/ruifm/aidock/actions/workflows/ci.yml/badge.svg)](https://github.com/ruifm/aidock/actions/workflows/ci.yml)
[![Bash](https://img.shields.io/badge/language-bash-green.svg)](src/aidock)
[![Podman](https://img.shields.io/badge/engine-podman%20%7C%20docker-orange.svg)](#how-it-works)

Run AI coding agents (Copilot CLI, Claude Code, Codex) inside a container. One command, container-isolated, batteries included.

---

- [Why](#why)
- [Features](#features)
- [Quick start](#quick-start)
- [Usage](#usage)
- [What's inside](#whats-inside)
- [Configuration](#configuration)
- [How it works](#how-it-works)
- [Comparison](#comparison)
- [Limitations](#limitations)
- [Uninstall](#uninstall)
- [License](#license)

## Why

AI coding agents run with full access to your filesystem, environment variables, and credentials. One bad tool call can `rm -rf` your home directory or exfiltrate secrets from `~/.ssh`. Sandboxing fixes this, but setting it up properly is tedious: user namespace mapping, auth forwarding, path consistency, toolchain installation, MCP server configuration.

aidock handles all of that. You get a single self-extracting script that builds a container image with everything an AI agent needs to be productive, then drops you into a session where the agent can see your project directory and its own config, but not the rest of your host filesystem.

## Features

- **Agent-agnostic.** Switch between Copilot CLI, Claude Code, and Codex with `-a claude`. All three are pre-installed and pre-configured with MCP servers.
- **Batteries included.** 4 language toolchains (Node, Python, Rust, Go), 9 LSPs, debuggers (gdb, valgrind, strace), document analysis (pdftotext, tesseract, pandoc), image manipulation (ImageMagick), and 4 MCP servers. Agents don't waste your tokens installing common tools.
- **Declarative environment.** The Containerfile IS the environment spec. Want a tool? Edit it and rebuild. The container filesystem is ephemeral — packages installed during a session are discarded on exit, preventing drift. Agent config and session history persist in `~/.config/aidock/`.
- **Zero-config path mirroring.** Your project is mounted at the same absolute path inside the container. File references in agent output, error messages, and logs point to real paths on your host.
- **Single file, no dependencies.** `aidock` is a self-extracting Bash script. It needs Podman or Docker and nothing else. No Node.js, no Python, no package manager.
- **Your config, your image.** All configuration is seeded to `~/.config/aidock/` on first run. Edit freely; your changes are preserved across updates. `aidock reset` re-seeds defaults without touching session data.
- **Safe by default.** Files created by the agent are owned by your user (namespace mapping). Containers are ephemeral (`--rm`). Reset is non-destructive unless you explicitly `--purge`.

## Quick start

**Requirements:** [Podman](https://podman.io/docs/installation) (preferred) or Docker.

```bash
# Grab the script
curl -fsSL https://raw.githubusercontent.com/ruifm/aidock/main/aidock -o ~/.local/bin/aidock
chmod +x ~/.local/bin/aidock
```

Or clone the repo and copy the script somewhere in your `$PATH`:

```bash
git clone https://github.com/ruifm/aidock.git
cp aidock/aidock ~/.local/bin/    # or /usr/local/bin/, ~/bin/, etc.
```

Then, from any project directory:

```bash
aidock              # launch Copilot CLI (default)
aidock -a claude    # launch Claude Code
aidock -a codex     # launch Codex
```

The first run builds the container image. This takes a few minutes; subsequent launches are instant.

> **Note:** Copilot CLI is the primary tested agent. Claude Code and Codex are supported but less thoroughly tested. Contributions to improve their configuration and integration are welcome.

## Usage

```
aidock [command] [options] [-- agent-args...]
```

| Command | Description |
|---------|-------------|
| `run` | Launch agent in container (default if omitted) |
| `build` | Build the container image |
| `update` | Pull latest base image and rebuild |
| `clean` | Remove image and config |
| `shell` | Open a debug shell in the container |
| `check` | Run the container healthcheck |
| `info` | Show engine, image, and agent info |
| `reset` | Re-seed config from defaults |
| `diff` | Show config drift from defaults |

### Common workflows

```bash
# Switch agents
aidock -a claude

# Pass flags to the agent binary
aidock -- --help                  # show agent's own help
aidock -a claude -- --verbose     # verbose mode for Claude

# Image management
aidock build                      # build image
aidock build --no-cache           # force full rebuild
aidock update                     # pull latest base + rebuild

# Configuration
aidock info                       # show engine, image, config paths
aidock diff                       # show what you've changed vs defaults
aidock reset                      # re-seed build files (Containerfile, etc.)
aidock reset -a claude            # re-seed claude config only
aidock reset --purge -a claude    # delete all claude config + session data

# Debugging
aidock shell                      # drop into the container without an agent
aidock check                      # run container healthcheck
```

### Agent authentication

| Agent | Auth |
|-------|------|
| Copilot | `GH_TOKEN` env var, or auto-detected from `gh auth token` |
| Claude | `ANTHROPIC_API_KEY` env var |
| Codex | `OPENAI_API_KEY` env var |

Tokens are forwarded into the container but never written to disk or logged.

## What's inside

The default image is based on Fedora and includes:

| Category | Tools |
|----------|-------|
| Languages | Node.js, Python 3, Rust, Go |
| LSPs | typescript-language-server, basedpyright, rust-analyzer, clangd, bash-language-server, lua-language-server, dockerfile-language-server, yaml-language-server, vscode-langservers-extracted (CSS/HTML/JSON) |
| Build systems | make, cmake, gcc, g++, clang |
| Debugging | gdb, valgrind, strace, ltrace |
| Document analysis | pdftotext, tesseract OCR, pandoc, w3m, xmlstarlet |
| Image & media | ImageMagick |
| Python libraries | openpyxl (Excel), Pillow (images), python-docx (Word) |
| MCP servers | Context7, Sequential Thinking, Playwright, Firecrawl |
| Formatters | prettier, ruff, rustfmt, shfmt |
| Search & nav | ripgrep, fd, jq, tree |
| AI agents | Copilot CLI, Claude Code, Codex |

Agents don't need to spend tokens installing any of this. If a tool is missing, add it to your Containerfile and rebuild.

## Configuration

All config lives in `~/.config/aidock/` (respects `$XDG_CONFIG_HOME`):

```
~/.config/aidock/
├── Containerfile        # image definition — edit to add packages
├── init-home.sh         # container entrypoint
├── checkhealth.sh       # healthcheck script
├── agents/              # default agent configs (baked into image)
├── container.conf       # extra engine args (one per line)
├── default-agent        # preferred agent name (e.g., "claude")
├── copilot/             # copilot config + session data
├── claude/              # claude config + session data
└── codex/               # codex config + session data
```

### Customizing the image

Edit `~/.config/aidock/Containerfile` and rebuild:

```bash
# Add your tools
echo 'RUN dnf install -y htop tmux' >> ~/.config/aidock/Containerfile
aidock build

# See what you've changed
aidock diff

# Reset to defaults (preserves session data)
aidock reset
```

### Extra container engine args

Add persistent Podman/Docker flags to `~/.config/aidock/container.conf` (one per line):

```
--publish=3000:3000
--env=MY_CUSTOM_VAR=value
--volume=/data:/data:ro
```

### Default agent

Write a name to `~/.config/aidock/default-agent` to change the default from `copilot`:

```bash
echo claude > ~/.config/aidock/default-agent
```

## How it works

aidock is a Bash script (~700 lines) that orchestrates Podman or Docker. Each session:

1. **Seeds config** on first run (`cp -n` from embedded defaults to `~/.config/aidock/`).
2. **Builds the image** from your Containerfile if needed (timestamp-based rebuild detection).
3. **Launches an ephemeral container** (`--rm`) with your project bind-mounted at the same absolute path, agent config mounted, and auth tokens forwarded.
4. **Runs the agent** with maximum permissions (no approval prompts, no sandbox restrictions — the container IS the sandbox).

### What gets mounted

| Host path | Container path | Mode |
|-----------|---------------|------|
| Git repository root (or `$PWD`) | Same absolute path | read-write |
| `~/.config/aidock/<agent>/` | Agent config dir (`~/.copilot/`, etc.) | read-write |

### Engine auto-detection

aidock prefers Podman over Docker. Override with `CONTAINER_ENGINE=docker`.

Under Podman, `--userns=keep-id` maps your host UID into the container so files the agent creates are owned by you. Under Docker, `--user $(id -u):$(id -g)` achieves the same effect.

### Ephemeral by design

Containers run with `--rm`. Anything an agent installs during a session (packages, global npm modules) is discarded when the session ends. This is intentional: it prevents environment drift and keeps every session reproducible. If a tool proves useful, add it to your Containerfile and rebuild.

Agent config and session history (under `~/.config/aidock/<agent>/`) persist across sessions via bind mounts and are not affected by container ephemerality.

## Comparison

| | aidock | code-container | aipod | devcontainers |
|-|--------|---------------|-------|---------------|
| Language | Bash (single file) | TypeScript (npm) | POSIX sh | JSON spec + CLI |
| Container engine | Podman + Docker | Docker (+ Podman in fork) | Podman only | Docker / Podman |
| Container model | Ephemeral (`--rm`) | Persistent | Persistent + snapshots | Persistent |
| Path handling | CWD mirrored (same paths) | Mounts to `/root/project` | Manual mount management | Workspace mount |
| Agent support | Copilot, Claude, Codex | Claude, Codex | Claude, Codex | Any (manual setup) |
| Pre-installed tools | 4 toolchains, 9 LSPs, MCP servers, debuggers, document analysis | Build tools, optional agents | Build tools, no LSPs/MCP | User-defined |
| Config customization | Edit Containerfile, rebuild | `extra_packages.apt` | Edit Dockerfile | devcontainer.json |
| State drift | Impossible (ephemeral container fs) | Accumulates over time | Accumulates + snapshots | Accumulates over time |
| Dependencies | None (just Bash + engine) | Node.js + npm | None (just sh + Podman) | Node.js + CLI |
| Install | Copy one file | `npm install -g` | Clone repo | VS Code extension / CLI |

## Limitations

- **Network is not sandboxed.** The container has full network access. Agents can make HTTP requests, install packages, and reach external services.
- **Agent config persists.** While the container filesystem is ephemeral, agent configuration and session history under `~/.config/aidock/` persist across runs (this is by design, so agents can resume sessions).
- **First build requires internet.** The initial image build downloads Fedora packages, npm modules, and Rust toolchain. Subsequent runs are offline-capable.
- **Podman vs Docker.** Both work, but Podman provides stronger isolation via rootless user namespaces. Docker requires `--user` mapping which has some edge cases with file permissions.

## Uninstall

```bash
aidock clean              # remove image and config
rm ~/.local/bin/aidock    # remove the launcher
```

## License

[MIT](LICENSE)
