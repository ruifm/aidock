# Copilot Instructions

## Project overview

aidock is a container wrapper that runs AI coding agents (Copilot CLI, Claude Code, Codex) inside per-CWD stateful Podman/Docker containers. It is a single self-contained Bash script with default Containerfile/init-home/checkhealth contents inlined as heredocs.

## Repository layout

- `aidock` — the launcher script. This is the file users install and run; there is no separate dist/build step.
- `tests/integration.sh` — unit and integration test suite.
- `justfile` — task runner recipes and single source of truth for the project name.
- `~/.config/aidock/` (per-user, not in repo) — `Containerfile`, `init-home.sh`, `checkhealth.sh`, `aidock.conf`, seeded on first run from inline heredocs in `aidock`. User edits there are preserved.

## Development rules

- Edit `aidock` directly. There is no generated copy.
- The default Containerfile / init-home.sh / checkhealth.sh live inline in `aidock` as quoted heredocs (`emit_containerfile`, `emit_init_home`, `emit_checkhealth`). Use `aidock --emit-default <name>` to print one out (used by `just lint` for hadolint).
- Run `just check` before committing (formats, lints, runs unit tests).
- Use `just fmt` to format (shfmt for Bash, prettier for JSON/YAML).
- Use conventional commits: `feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`.
- Each commit must pass `just check` and address a single concern.

## Code style

- Bash: 4-space indent, case-indent (`shfmt -i 4 -ci`), ShellCheck clean.
- All Bash functions and variables use snake_case.
- The launcher uses `set -euo pipefail` and a `die()` helper for error exits.

## Architecture notes

- **Project name SSOT**: hardcoded default `aidock` inside the launcher, overridable via the `PROJECT_NAME` env var (the justfile exports it for tests).
- **Config seeding**: on first run, defaults are extracted to `~/.config/aidock/` via `cp -n`. User edits are preserved.
- **Rebuild detection**: timestamp-based comparison of config files against a `.last-build` marker.
- **User namespace mapping**: Podman uses `--userns=keep-id`; Docker uses `--user` with dynamic passwd entry.
- **CWD mirroring**: the project is mounted at the same absolute path inside the container.
- **Agent abstraction**: a case statement in `aidock` maps agent names to their CLI commands, config dirs, and auth mechanisms.

## Testing

- `just test-unit` — fast unit tests (no container needed). Tests CLI parsing, config seeding, subcommand behavior.
- `just test` — builds the image and runs integration tests including container healthcheck.
- When adding a feature, add corresponding tests. When fixing a bug, add a regression test first.
