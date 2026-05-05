#!/usr/bin/env bash
# init-home.sh: Per-container entrypoint. Ensures a writable home for the
# current UID and links any host-mounted configs the agent expects.
#
# All env vars are set by aidock (required).

set -euo pipefail

: "${AGENT:?}" "${AGENT_CONFIG_DIR:?}" "${PROJECT_NAME:?}"

# Ensure current UID has a passwd entry (needed for Docker --user, no-op when running as root)
if [[ "$(id -u)" != "0" ]] && ! getent passwd "$(id -u)" &>/dev/null; then
    echo "${PROJECT_NAME}:x:$(id -u):$(id -g)::${HOME}:/bin/bash" >>/etc/passwd
fi

CONFIG_TARGET="${HOME}/${AGENT_CONFIG_DIR}"

mkdir -p "${CONFIG_TARGET}"

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
