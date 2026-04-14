# Copilot Instructions

## Project overview

aidock is a container wrapper that runs AI coding agents (Copilot CLI, Claude Code, Codex) inside an ephemeral Podman/Docker container. It is a single self-extracting Bash script with embedded default assets.

## Repository layout

- `src/aidock` — **dev source** of the launcher script. All code changes go here.
- `aidock` — **generated** distributable. Never edit directly. Regenerate with `just dist`.
- `src/build-dist.sh` — builds `./aidock` by embedding `defaults/` as a base64 tarball.
- `defaults/Containerfile` — Fedora-based container image definition.
- `defaults/init-home.sh` — container entrypoint script.
- `defaults/checkhealth.sh` — container healthcheck (run via `aidock check`).
- `defaults/agents/` — per-agent default configs (copilot, claude, codex).
- `tests/integration.sh` — unit and integration test suite.
- `justfile` — task runner recipes and single source of truth for the project name.

## Development rules

- Edit `src/aidock`, never `./aidock`. Run `just dist` to regenerate the distributable.
- Run `just check` before committing (formats, lints, rebuilds dist, runs unit tests).
- Use `just fmt` to format (shfmt for Bash, prettier for JSON/YAML).
- Use conventional commits: `feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`.
- Each commit must pass `just check` and address a single concern.

## Code style

- Bash: 4-space indent, case-indent (`shfmt -i 4 -ci`), ShellCheck clean.
- All Bash functions and variables use snake_case.
- The launcher uses `set -euo pipefail` and a `die()` helper for error exits.

## Architecture notes

- **Project name SSOT**: defined once in the justfile as `PROJECT_NAME`, flows via env vars to all components.
- **Config seeding**: on first run, defaults are extracted to `~/.config/aidock/` via `cp -n`. User edits are preserved.
- **Rebuild detection**: timestamp-based comparison of config files against a `.last-build` marker.
- **User namespace mapping**: Podman uses `--userns=keep-id`; Docker uses `--user` with dynamic passwd entry.
- **CWD mirroring**: the project is mounted at the same absolute path inside the container.
- **Agent abstraction**: a case statement in `src/aidock` maps agent names to their CLI commands, config dirs, and auth mechanisms.

## Testing

- `just test-unit` — fast unit tests (no container needed). Tests CLI parsing, config seeding, subcommand behavior.
- `just test` — builds the image and runs integration tests including container healthcheck.
- When adding a feature, add corresponding tests. When fixing a bug, add a regression test first.
