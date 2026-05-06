# aidock

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![CI](https://github.com/ruifm/aidock/actions/workflows/ci.yml/badge.svg)](https://github.com/ruifm/aidock/actions/workflows/ci.yml)
[![Bash](https://img.shields.io/badge/language-bash-green.svg)](aidock)

Run AI coding agents (Copilot CLI, Claude Code, Codex) inside per-project, stateful Podman/Docker containers. One Bash script, no dependencies beyond the engine.

```bash
aidock              # launch your default agent in this project's container
aidock -a claude    # switch agent
aidock shell        # debug shell
```

## Why

AI coding agents run with full access to your filesystem and credentials. aidock puts them in a container that:

- mounts only your project (same absolute path inside and out),
- forwards the agent's host auth and stable rule files (e.g. `CLAUDE.md`),
- commits the container on exit so installs (`dnf`, `pip`, `npm -g`) and self-updates persist per project.

## Install

Requires [Podman](https://podman.io/docs/installation) (preferred) or Docker.

```bash
curl -fsSL https://raw.githubusercontent.com/ruifm/aidock/main/aidock -o ~/.local/bin/aidock
chmod +x ~/.local/bin/aidock
```

Or `git clone https://github.com/ruifm/aidock.git && cd aidock && just install`.

## Quick start

```bash
cd my-project
aidock              # first run builds the base image (a few minutes)
```

aidock probes your host for each agent's auth and uses what you have:

| Agent | Configured if any of |
|-------|---------------------|
| Copilot | `GH_TOKEN` set, or `gh auth token` succeeds, or `~/.config/github-copilot/hosts.json` exists |
| Claude | `ANTHROPIC_API_KEY` set, or `~/.claude/.credentials.json` exists |
| Codex | `OPENAI_API_KEY` set, or `~/.codex/auth.json` exists |

If only one is configured, aidock autoselects it. If two or more, it shows a TTY picker (unconfigured agents listed read-only with their setup hint). If none, aidock exits with hints:

| Agent | Setup |
|-------|-------|
| Copilot | `gh auth login` (then enable Copilot), or set `GH_TOKEN` |
| Claude | Set `ANTHROPIC_API_KEY`, or run `claude /login` once on the host |
| Codex | Set `OPENAI_API_KEY`, or run `codex login` once on the host |

## Commands

```
aidock [command] [options] [-- agent-args...]
```

| Command | Description |
|---------|-------------|
| `run` (default) | Launch agent in container |
| `shell` | Debug shell in container |
| `update` | Update agents in the shared agents volume (global) |
| `info` | Show engine, image, and agent info |
| `clean` | Remove base image, agents volume, and dangling layers |
| `purge` | Delete per-agent host config (`-a NAME` to scope; `--force` to skip prompt) |
| `list-sessions` | List recorded per-project sessions |
| `drop-session` | Drop this CWD's session image (next run uses base) |
| `prune` | Show (or remove with `--orphans`) sessions whose CWD is gone |

Common flags: `-a/--agent NAME`, `-n/--dry-run`, `--no-cache`, `--commit always|prompt|never`.

## Configuration

A single optional file: `~/.config/aidock/aidock.conf` (bash-sourced).

```bash
# Default agent if -a is omitted; empty → prompt picker.
default_agent=copilot

# Behavior when the container's filesystem changed at exit:
#   always  Commit the change to this project's session image. (default)
#   prompt  Ask interactively (10s timeout; Enter commits, timeout discards).
#   never   Discard changes (back to base on next run).
commit_on_exit=always

# Extra args appended to every `engine run` (mounts, ports, env).
extra_container_args=(-v "$HOME/.foo:/root/.foo:ro" --publish=3000:3000)
```

CLI flags override values here. Per-project session metadata lives under `~/.local/share/aidock/sessions/`.

### Recommended agent rule snippet

aidock containers run as root with full permissions. Tell your agent it can act freely inside the container:

> You are running inside [aidock](https://github.com/ruifm/aidock): a Fedora container with full root permissions and only the current project bind-mounted from the host. Anything you install (`dnf install`, `pip install`, `npm install -g`, etc.) persists across runs because the container is committed on exit. The container is the sandbox — do not ask permission to run destructive commands inside it. If you need anything from the host (config outside the project, global git changes, access to other repos), tell me explicitly so I can do it from the host. The base image is intentionally minimal: if you want a language server or an MCP server, install and configure it yourself; the next run will already have it.

Per-agent file conventions:

| Agent | Repo-level | User-level |
|-------|-----------|-----------|
| Copilot | `.github/copilot-instructions.md` | (memory / settings UI) |
| Claude | `CLAUDE.md` | `~/.claude/CLAUDE.md` |
| Codex | `AGENTS.md` | `~/.codex/AGENTS.md` |

## How it works

Each `aidock` invocation:

1. Hashes the current working directory.
2. Picks the image: `<project>-session-<hash>:latest` if it exists, else `<project>-base:latest` (built on first run).
3. Launches a container with your project bind-mounted at the same absolute path, the agent's allowlisted host config files mounted in, and auth tokens forwarded.
4. On exit, diffs the container; if anything changed, applies `commit_on_exit` (commit / prompt / never).

Agent CLIs (`copilot`, `claude`, `codex`) live in a shared `aidock-agents` named volume mounted at `/opt/aidock/agents`, so `aidock update` refreshes them globally for every project at once. Per-project chat history and downloaded data stay inside that project's session image — different projects don't see each other's session pickers.

Podman uses `--userns=keep-id`; Docker uses `--user $(id -u):$(id -g)`. Either way, files the agent creates are owned by you. A per-hash `flock` serializes concurrent launches in the same directory.

## Limitations

- Network is not sandboxed.
- First build requires internet.
- State drift is per-project by design. `aidock drop-session` is the eject button.

## Uninstall

```bash
aidock clean
rm -rf ~/.config/aidock ~/.local/share/aidock
rm ~/.local/bin/aidock
```

## License

[MIT](LICENSE)
