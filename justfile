# aidock: AI dev container management
# Usage: just <recipe>

export PROJECT_NAME := "aidock"
launcher := "./" + PROJECT_NAME

# Build the container image
build:
    {{launcher}} build

# Force rebuild (no cache)
rebuild:
    {{launcher}} build --no-cache

# Rebuild with latest base image and packages
update:
    {{launcher}} update

# Launch agent in container (from current directory)
run *args:
    {{launcher}} {{args}}

# Run container healthcheck + integration tests
test: build
    ./tests/integration.sh

# Run unit tests only (no container image needed)
test-unit: dist
    ./tests/integration.sh --unit

# Open a shell inside the container for debugging
shell *args:
    {{launcher}} shell {{args}}

# Install the distributable launcher into PATH
install: dist
    mkdir -p "${HOME}/.local/bin"
    cp {{launcher}} "${HOME}/.local/bin/{{PROJECT_NAME}}"
    @echo "Installed: ~/.local/bin/{{PROJECT_NAME}}"
    @case ":${PATH}:" in *":${HOME}/.local/bin:"*) ;; *) \
        printf '⚠  ~/.local/bin is not in your PATH. Add it with:\n   echo '"'"'export PATH="$HOME/.local/bin:$PATH"'"'"' >> ~/.bashrc && source ~/.bashrc\n' ;; esac

# Remove the image, config, and dangling layers
clean:
    {{launcher}} clean

# Show image and agent info
info:
    {{launcher}} info

# ── Code quality ─────────────────────────────────────────────────────

bash_files := "src/aidock defaults/init-home.sh defaults/checkhealth.sh tests/integration.sh src/build-dist.sh"

# Format all source files
fmt:
    shfmt -w -i 4 -ci {{bash_files}}
    prettier --write "**/*.json" "**/*.yml" "**/*.yaml"

# Lint all source files
lint:
    shellcheck {{bash_files}}
    yamllint -c .yamllint.yml .github/workflows/ .yamllint.yml .hadolint.yaml
    hadolint defaults/Containerfile
    @echo "Validating JSON..."; for f in $(find . -name '*.json' -not -path './node_modules/*'); do jq empty "$f" || exit 1; done

# Generate distributable script with embedded assets
dist:
    src/build-dist.sh

# Format + lint + dist + unit tests
check: fmt lint dist test-unit

# Install git pre-commit hook
install-hooks:
    git config core.hooksPath .githooks
    @echo "Installed: .githooks/pre-commit"
