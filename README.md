# aidock

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![CI](https://github.com/ruifm/aidock/actions/workflows/ci.yml/badge.svg)](https://github.com/ruifm/aidock/actions/workflows/ci.yml)
[![Bash](https://img.shields.io/badge/language-bash-green.svg)](aidock)
[![Podman](https://img.shields.io/badge/engine-podman%20%7C%20docker-orange.svg)](#how-it-works)

Run AI coding agents (Copilot CLI, Claude Code, Codex) inside a per-project, stateful container. One command, container-isolated, batteries included.

---

- [Why](#why)
- [Quick start](#quick-start)
- [Usage](#usage)
- [What's inside](#whats-inside)
- [Configuration](#configuration)
- [How it works](#how-it-works)
- [Limitations](#limitations)
- [Uninstall](#uninstall)
- [License](#license)

## Why

AI coding agents run with full access to your filesystem, environment variables, and credentials. One bad tool call can `rm -rf` your home directory or exfiltrate secrets from `~/.ssh`. Sandboxing fixes this, but setting it up properly is tedious: user namespace mapping, auth forwarding, path consistency, toolchain installation, MCP server configuration.

aidock handles all of that. You get a single Bash script that builds a container image, launches your agent inside it, and remembers the state of each project's container so installs and self-updates persist across sessions — without ever leaving the sandbox.

## Features

- **Agent-agnostic.** Switch between Copilot CLI, Claude Code, and Codex with `-a claude`. All three are pre-installed.
- **Stateful per project.** Each working directory gets its own committed image. Anything the agent installs (apt/dnf packages, language toolchains, global npm modules) and any agent self-update is captured on exit and re-used next time. No more "I told the agent to install something and it forgot".
- **Slim by default, grows with use.** The base image ships with Node, Python, and the three AI agents. Heavier toolchains (Rust, Go, native build tools) and project-specific tooling (LSPs, MCP servers) are installed on demand and persisted via the per-project commit.
- **Single file, no dependencies.** `aidock` is a Bash script. It needs Podman or Docker and nothing else.
- **Zero-config path mirroring.** Your project is mounted at the same absolute path inside the container. File references in agent output, error messages, and logs point to real paths on your host.
- **Safe by default.** Files created by the agent are owned by your user (namespace mapping). Network is open; the host filesystem is not.

## Quick start

**Requirements:** [Podman](https://podman.io/docs/installation) (preferred) or Docker.

```bash
# Grab the script
curl -fsSL https://raw.githubusercontent.com/ruifm/aidock/main/aidock -o ~/.local/bin/aidock
chmod +x ~/.local/bin/aidock
```

Or clone the repo and run `just install`:

```bash
git clone https://github.com/ruifm/aidock.git
cd aidock
just install
```

Then, from any project directory:

```bash
aidock              # launch Copilot CLI (default)
aidock -a claude    # launch Claude Code
aidock -a codex     # launch Codex
```

The first run builds the base image; this takes a few minutes. Subsequent launches are instant.

> **Note:** Copilot CLI is the primary tested agent. Claude Code and Codex are supported but less thoroughly tested.

## Usage

```
aidock [command] [options] [-- agent-args...]
```

| Command | Description |
|---------|-------------|
| `run` | Launch agent in container (default if omitted) |
| `build` | Build the base container image |
| `update` | Pull latest base image and rebuild |
| `update-agents` | Re-install AI agents inside the current project's session image |
| `clean` | Remove images and config |
| `shell` | Open a debug shell in the container |
| `check` | Run the container healthcheck |
| `info` | Show engine, image, and agent info |
| `reset` | Re-seed config from defaults (use `--session` to drop the per-project image) |
| `list-sessions` | List recorded per-project session images |

### Common workflows

```bash
# Switch agents
aidock -a claude

# Pass flags to the agent binary
aidock -- --help                  # show agent's own help
aidock -a claude -- --verbose     # verbose mode for Claude

# Image management
aidock build                      # build base image
aidock build --no-cache           # force full rebuild
aidock update                     # pull latest base + rebuild
aidock update-agents              # bump agent versions inside this project's image

# Project sessions
aidock list-sessions              # which projects have committed state
aidock reset --session            # drop this project's image, fall back to base
aidock info                       # show engine, image, config paths

# Debugging
aidock shell                      # drop into the container without an agent
aidock check                      # run container healthcheck
```

### Agent authentication

aidock probes your host for each agent's auth and uses the result to decide which agents are usable. An agent is considered configured when **any one** of these is true:

| Agent | Configured if any of |
|-------|---------------------|
| Copilot | `GH_TOKEN` set, or `gh auth token` succeeds, or `~/.config/github-copilot/hosts.json` exists |
| Claude | `ANTHROPIC_API_KEY` set, or `~/.claude/.credentials.json` exists |
| Codex | `OPENAI_API_KEY` set, or `~/.codex/auth.json` exists |

Setup hints if you're missing one:

| Agent | Setup |
|-------|-------|
| Copilot | `gh auth login` (then enable Copilot), or set `GH_TOKEN` |
| Claude | Set `ANTHROPIC_API_KEY`, or run `claude /login` once on the host |
| Codex | Set `OPENAI_API_KEY`, or run `codex login` once on the host |

A per-agent allowlist bind-mounts the host's auth tokens, credential files, and stable settings/rule files (e.g. `settings.json`, `CLAUDE.md`, `AGENTS.md`, `~/.config/github-copilot/skills/`) into the container so login state and your hand-authored config follow you across projects. Agent session history and chat data are **not** mounted — they live inside the per-project committed image, so different projects never see each other's chat picker.

#### Picking an agent

When you run `aidock` without `-a` and without a `default-agent` file, the launcher picks one based on what's configured on your host:

- **0 configured** — die and print the setup hint for all three agents.
- **1 configured** — autoselect it and log `[info] autoselected: <agent>`.
- **2+ configured** — show a numbered TTY picker. Unconfigured agents are listed in a separate non-selectable section with their setup hint. With no TTY (e.g. piped input) the launcher dies and points you at `-a` or `default-agent`.

Explicit selection (`-a claude` or `default-agent` file) is a hard contract: if that agent isn't configured on the host, `aidock run` dies with the agent's setup hint. `aidock shell` only warns, since shell mode is a debug escape hatch.

`aidock update-agents` filters the same way — it only reinstalls agents that are configured on your host. The base image still ships all three agents, so adding auth for a new one later just works on the next run.

#### Recommended rule-file snippet

aidock containers run as root with full permissions and only your project bind-mounted from the host. Tell your agent it can act freely inside the container — it removes a lot of "may I run this?" friction. Drop something like the following into your agent's instruction file:

> You are running with full root permissions inside a Fedora container with only the current project bind-mounted from the host. Anything you install (`dnf install`, `pip install`, `npm install -g`, etc.) persists across runs because the container is committed on exit. The container is the sandbox — do not ask permission to run destructive commands inside it. If you need anything from the host (config outside the project, global git changes, access to other repos), tell me explicitly so I can do it from the host. The base image is intentionally minimal: if you want a language server or an MCP server, install and configure it yourself; the next run will already have it.

Per-agent file conventions:

| Agent | Repo-level | User-level |
|-------|-----------|-----------|
| Copilot | `.github/copilot-instructions.md` | (memory / settings UI) |
| Claude | `CLAUDE.md` | `~/.claude/CLAUDE.md` |
| Codex | `AGENTS.md` | `~/.codex/AGENTS.md` |

## What's inside

The base image is Fedora-based and intentionally lean:

| Category | Tools |
|----------|-------|
| Languages | Node.js, Python 3 |
| Formatters / linters | prettier, ruff, ShellCheck |
| Search & nav | ripgrep, fd, jq, tree, less |
| Misc | git, curl, wget, diffutils, patch, sudo, just, sqlite |
| AI agents | Copilot CLI, Claude Code, Codex |

Heavier tooling (Rust, Go, gcc/g++, debuggers, document/media tooling) is **not** in the base image. If your project needs it, ask the agent to install it; the per-project commit will persist the install for next time.

### Why no LSPs or MCP servers?

Earlier versions pre-installed a fixed set of language servers and MCP servers. They were dropped because:

- **MCP servers need per-agent config.** Pre-installing the binary doesn't help if no agent is configured to call it. Reusing the host's MCP config is a non-starter — MCP configs reference host paths and host-only tooling.
- **LSPs are aspirational.** None of the supported agents currently drive a language server.
- **The commit-on-exit model handles it.** Tell the agent "install the typescript LSP" or "set up the Playwright MCP server" once; the per-CWD commit persists that install across runs. It's a one-time setup per project.

If you want a default rule snippet for your agent that nudges this behavior, see the [Recommended rule-file snippet](#recommended-rule-file-snippet) section above.

> Existing per-CWD images built before this change still contain the old LSP/MCP packages. Run `aidock reset` then `aidock build` to rebuild a slimmer base, or just leave them — they're harmless.

## Configuration

All config lives in `~/.config/aidock/` (respects `$XDG_CONFIG_HOME`):

```
~/.config/aidock/
├── Containerfile        # base image definition — edit to customize
├── aidock               # the launcher itself, copied here so the image can COPY it
├── aidock.conf          # commit_on_exit policy, etc.
├── container.conf       # extra engine args (one per line)
└── default-agent        # preferred agent name (e.g., "claude")
```

`Containerfile` is seeded from an inline heredoc in `aidock` itself; user edits there are preserved across upgrades. The container's entrypoint and healthcheck logic live as hidden subcommands inside the launcher (`aidock __init-home`, `aidock __checkhealth`), so the image just `COPY`s the launcher in. Per-project session metadata lives under `~/.local/share/aidock/sessions/`.

### `aidock.conf`

```
# Behavior on container exit when the container's filesystem changed:
#   always  Commit the change to the per-project session image. (default)
#   prompt  Ask interactively (10s timeout; Enter commits, timeout discards).
#   never   Discard changes (back to base image on next run).
commit_on_exit=always
```

CLI override: `aidock run --commit=prompt`. CLI flag wins over config file which wins over compiled-in default (`always`).

### Customizing the base image

Edit `~/.config/aidock/Containerfile` and rebuild:

```bash
echo 'RUN dnf install -y htop tmux' >> ~/.config/aidock/Containerfile
aidock build

# Reset the base Containerfile to defaults (preserves project sessions)
aidock reset
```

For a single project's needs, just have the agent install what it needs. The next exit's commit will keep it.

### Extra container engine args

Add persistent Podman/Docker flags to `~/.config/aidock/container.conf` (one per line):

```
--publish=3000:3000
--env=MY_CUSTOM_VAR=value
--volume=/data:/data:ro
```

aidock prints a one-line `[info] applied N extra container args from ...` notice on stderr when this file contributes any args (suppressed for `info` and `check`).

### Default agent

If you almost always use the same agent, write its name to `~/.config/aidock/default-agent` to skip the picker:

```bash
echo claude > ~/.config/aidock/default-agent
```

Without this file, the agent is chosen by the picker described under [Agent authentication](#agent-authentication).

## How it works

aidock is a Bash script that orchestrates Podman or Docker. Each session:

1. **Computes a project hash** from the realpath of the current working directory.
2. **Picks an image**: `<project>-session-<hash>:latest` if it exists, otherwise `<project>-base:latest`.
3. **Launches a container** with your project bind-mounted at the same absolute path, the agent's host config files allowlisted in, and auth tokens forwarded.
4. **Runs the agent** with maximum in-container permissions — the container is the sandbox.
5. **On exit**, runs `engine diff` to detect filesystem changes. If non-empty, applies the `commit_on_exit` policy (commit / prompt / never). Empty diffs skip commit and exit instantly.

### What gets mounted

| Host path | Container path | Mode |
|-----------|---------------|------|
| Git repository root (or `$PWD`) | Same absolute path | read-write |
| Per-agent allowlisted host config files (e.g. `~/.config/github-copilot/apps.json`) | Same path inside container | read-write |

Agent session history, chat data, and downloaded models live **inside** the per-project committed image, not bind-mounted from the host. That's why two project sessions don't see each other's chat picker.

### Engine auto-detection

aidock prefers Podman over Docker. Override with `CONTAINER_ENGINE=docker`.

Under Podman, `--userns=keep-id` maps your host UID into the container so files the agent creates are owned by you. Under Docker, `--user $(id -u):$(id -g)` achieves the same effect.

### Concurrency

A per-hash `flock` under `~/.local/share/aidock/sessions/<hash>.lock` serializes launches against the same project, so a second `aidock` in the same directory waits for the first.

## Limitations

- **Network is not sandboxed.** The container has full network access.
- **First build requires internet.** Subsequent runs are offline-capable.
- **State drift is per-project.** That's the design: a session image only ever grows from what *you* let it grow with. `aidock reset --session` is the eject button.
- **Podman vs Docker.** Both work, but Podman provides stronger isolation via rootless user namespaces.

## Uninstall

```bash
aidock clean              # remove all images (base + every project session)
rm -rf ~/.config/aidock ~/.local/share/aidock
rm ~/.local/bin/aidock
```

## License

[MIT](LICENSE)
