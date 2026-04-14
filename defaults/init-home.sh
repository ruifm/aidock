#!/usr/bin/env bash
# init-home.sh: Seed agent config from baked-in defaults if not already present.
# Used as ENTRYPOINT — runs before the AI agent starts.
#
# Config layering (per file, first match wins):
#   1. User override at /etc/$PROJECT_NAME/overrides/$file (bind-mounted from host)
#   2. Baked-in default at /etc/$PROJECT_NAME/agents/$AGENT/$file
#
# All env vars are set by aidock (required).

set -euo pipefail

: "${AGENT:?}" "${AGENT_CONFIG_DIR:?}" "${PROJECT_NAME:?}"

# Ensure current UID has a passwd entry (needed for Docker --user, no-op when running as root)
if [[ "$(id -u)" != "0" ]] && ! getent passwd "$(id -u)" &>/dev/null; then
    echo "${PROJECT_NAME}:x:$(id -u):$(id -g)::${HOME}:/bin/bash" >>/etc/passwd
fi

CONFIG_TARGET="${HOME}/${AGENT_CONFIG_DIR}"
DEFAULTS_DIR="/etc/${PROJECT_NAME}/agents/${AGENT}"

mkdir -p "${CONFIG_TARGET}"

# Seed config from baked-in defaults (only if file doesn't already exist)
if [[ -d "${DEFAULTS_DIR}" ]]; then
    for default_file in "${DEFAULTS_DIR}"/*; do
        [[ -f "$default_file" ]] || continue
        cp -n "$default_file" "${CONFIG_TARGET}/$(basename "$default_file")"
    done
fi

# Agent-specific post-assembly steps
if [[ "$AGENT" == "copilot" ]]; then
    # Link host-mounted copilot-instructions if available
    if [[ -n "${COPILOT_INSTRUCTIONS_HOST:-}" ]] && [[ -f "${COPILOT_INSTRUCTIONS_HOST}" ]]; then
        ln -sfn "${COPILOT_INSTRUCTIONS_HOST}" "${CONFIG_TARGET}/copilot-instructions.md"
    fi

    # Link host-mounted agents if available
    if [[ -d "${HOME}/.copilot-agents-host" ]]; then
        ln -sfn "${HOME}/.copilot-agents-host" "${CONFIG_TARGET}/agents"
    fi
fi

# Set minimal stat checks to avoid reindexing between host and container
if git rev-parse --git-dir &>/dev/null; then
    git config core.checkstat minimal
fi

exec "$@"
