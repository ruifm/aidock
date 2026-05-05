# Contributing to aidock

Thanks for your interest in contributing.

## Setup

Clone the repo and make sure you have these on your host:

- Bash 4+
- [just](https://github.com/casey/just) (task runner)
- [shfmt](https://github.com/mvdan/sh) (Bash formatter)
- [ShellCheck](https://www.shellcheck.net/) (Bash linter)
- [hadolint](https://github.com/hadolint/hadolint) (Containerfile linter)
- [prettier](https://prettier.io/) (JSON/YAML formatter)
- [yamllint](https://yamllint.readthedocs.io/) (YAML linter) and `jq` (JSON validator)
- [Podman](https://podman.io/) or Docker (for integration tests)

## Development workflow

The launcher is `aidock`. There is no separate generated distributable — `aidock` is what users install (e.g. via `just install`).

```bash
# Format, lint, run unit tests (the full CI gate)
just check

# Individual steps
just fmt         # format all source files
just lint        # lint Bash, YAML, JSON, and the inlined Containerfile
just test-unit   # run unit tests (no container needed)
just test        # build image + run full integration tests
```

The default `Containerfile` is inlined as a quoted heredoc inside `aidock` (`emit_containerfile`) and seeded to `~/.config/aidock/` on first run. The container's entrypoint and healthcheck are not separate files — they live as hidden subcommands of the launcher itself (`aidock __init-home`, `aidock __checkhealth`), and the image just `COPY`s the launcher in. To inspect or lint the embedded Containerfile:

```bash
aidock --emit-default Containerfile | hadolint -
```

## Code style

Bash files are formatted with `shfmt -i 4 -ci` (4-space indent, case indent). JSON/YAML with `prettier`. Run `just fmt` before committing.

All Bash is linted with ShellCheck. The Containerfile is linted with hadolint.

## Commits

Use [conventional commits](https://www.conventionalcommits.org/):

- `feat:` new feature
- `fix:` bug fix
- `docs:` documentation only
- `refactor:` no behavior change
- `test:` test additions or fixes
- `chore:` build, CI, tooling

Each commit should pass `just check`. Use `just install-hooks` to set up the pre-commit hook.

## Pull requests

1. Fork the repo and create a branch from `main`.
2. Make your changes in `aidock`.
3. Run `just check` — all tests must pass.
4. Open a PR with a clear description of what changed and why.

## Testing

Tests live in `tests/integration.sh`. There are two modes:

- **Unit tests** (`just test-unit`): fast, no container image needed. Tests CLI flag parsing, config seeding, subcommand behavior.
- **Integration tests** (`just test`): builds the image and runs healthchecks inside the container. Slower but validates the full stack.

When adding a feature, add tests for it. When fixing a bug, add a test that reproduces it first.
