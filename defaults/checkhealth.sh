#!/usr/bin/env bash
# checkhealth.sh: Verify the container environment is correctly configured.
# Run via: just test
# shellcheck disable=SC2015  # A && B || C pattern is intentional for pass/warn reporting
# shellcheck disable=SC2329,SC2317  # check_json is invoked dynamically

set -uo pipefail

: "${AGENT:?}" "${AGENT_CONFIG_DIR:?}" "${PROJECT_NAME:?}"

PASS=0
FAIL=0
WARN=0

pass() {
    printf "  \033[32m✓\033[0m %s\n" "$1"
    PASS=$((PASS + 1))
}
fail() {
    printf "  \033[31m✗\033[0m %s\n" "$1"
    FAIL=$((FAIL + 1))
}
warn() {
    printf "  \033[33m!\033[0m %s\n" "$1"
    WARN=$((WARN + 1))
}
section() { printf "\n\033[1;36m── %s ──\033[0m\n" "$1"; }

check_bin() {
    local name="$1" path="$2"
    if [[ "$path" == "PATH" ]]; then
        if command -v "$name" &>/dev/null; then
            pass "$name ($(command -v "$name"))"
        else
            fail "$name not found in PATH"
        fi
    elif [[ -x "$path" ]]; then
        pass "$name ($path)"
    else
        fail "$name not found at $path"
    fi
}

check_json() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        fail "$file missing"
    elif jq . "$file" &>/dev/null; then
        pass "$file (valid JSON)"
    else
        fail "$file (invalid JSON)"
    fi
}

# Show whether a config file came from a user override or baked-in default
check_config_source() {
    local basename="$1"
    local config_file="${HOME}/${AGENT_CONFIG_DIR}/${basename}"
    local override="/etc/${PROJECT_NAME}/overrides/${basename}"
    local default="/etc/${PROJECT_NAME}/agents/${AGENT}/${basename}"

    if [[ ! -f "$config_file" ]]; then
        fail "${basename} missing"
        return
    fi

    if ! jq . "$config_file" &>/dev/null; then
        fail "${basename} (invalid JSON)"
        return
    fi

    if [[ -f "$override" ]] && cmp -s "$config_file" "$override"; then
        pass "${basename} (user override)"
    elif [[ -f "$default" ]] && cmp -s "$config_file" "$default"; then
        pass "${basename} (baked-in default)"
    else
        pass "${basename} (valid JSON)"
    fi
}

# ── Environment ──────────────────────────────────────────────────────

section "Environment"

pass "AGENT=$AGENT"
pass "AGENT_CONFIG_DIR=$AGENT_CONFIG_DIR"
pass "PROJECT_NAME=$PROJECT_NAME"

if [[ -d "$HOME" ]] && [[ -w "$HOME" ]]; then
    pass "HOME=$HOME (writable)"
else
    fail "HOME=$HOME (not writable)"
fi

touch "$HOME/.checkhealth-test" 2>/dev/null && rm -f "$HOME/.checkhealth-test" &&
    pass "HOME write test" || fail "HOME write test"

[[ -n "${TERM:-}" ]] && pass "TERM=$TERM" || warn "TERM not set"
[[ -n "${LANG:-}" ]] && pass "LANG=$LANG" || warn "LANG not set"

id_output="$(id -u):$(id -g) ($(whoami 2>/dev/null || echo 'unknown'))"
pass "UID:GID = $id_output"

# ── CWD & mounts ─────────────────────────────────────────────────────

section "CWD & mounts"

cwd="$(pwd)"
pass "CWD=$cwd"

if [[ -d "$cwd" ]] && [[ -r "$cwd" ]]; then
    pass "CWD is readable"
else
    fail "CWD is not readable"
fi

if [[ -w "$cwd" ]]; then
    pass "CWD is writable"
else
    fail "CWD is not writable"
fi

if touch "$cwd/.checkhealth-mount-test" 2>/dev/null; then
    rm -f "$cwd/.checkhealth-mount-test"
    pass "CWD write test"
else
    fail "CWD write test (mount may be ro)"
fi

if ls "$cwd" &>/dev/null && [[ -n "$(ls -A "$cwd" 2>/dev/null)" || -d "$cwd" ]]; then
    file_count=$(find "$cwd" -maxdepth 1 -not -name '.' 2>/dev/null | wc -l)
    pass "CWD has $file_count entries (mount is live)"
else
    warn "CWD appears empty (mount may be missing)"
fi

# ── Agent configs ─────────────────────────────────────────────────────

section "Agent configs ($AGENT)"

# Dynamically check configs based on what's in the agent defaults dir
defaults_dir="/etc/${PROJECT_NAME}/agents/${AGENT}"
if [[ -d "$defaults_dir" ]]; then
    for default_file in "$defaults_dir"/*; do
        [[ -f "$default_file" ]] || continue
        basename="$(basename "$default_file")"
        config_file="${HOME}/${AGENT_CONFIG_DIR}/${basename}"
        if [[ ! -f "$config_file" ]]; then
            fail "${basename} missing"
        elif [[ "$basename" == *.json ]]; then
            check_config_source "$basename"
        elif [[ "$basename" == *.toml ]]; then
            # TOML: just verify the file exists and is non-empty
            if [[ -s "$config_file" ]]; then
                local_override="/etc/${PROJECT_NAME}/overrides/${basename}"
                if [[ -f "$local_override" ]] && cmp -s "$config_file" "$local_override"; then
                    pass "${basename} (user override)"
                elif cmp -s "$config_file" "$default_file"; then
                    pass "${basename} (baked-in default)"
                else
                    pass "${basename} (present)"
                fi
            else
                fail "${basename} (empty)"
            fi
        else
            pass "${basename} (present)"
        fi
    done
else
    warn "no default configs found for agent '$AGENT'"
fi

# Agent-specific config details
case "$AGENT" in
    copilot)
        config_file="${HOME}/${AGENT_CONFIG_DIR}/config.json"
        if [[ -f "$config_file" ]]; then
            model=$(jq -r '.model // "unset"' "$config_file" 2>/dev/null)
            effort=$(jq -r '.effortLevel // "unset"' "$config_file" 2>/dev/null)
            pass "model=$model effortLevel=$effort"
        fi
        ;;
esac

if [[ -w "$HOME/${AGENT_CONFIG_DIR}" ]] && touch "$HOME/${AGENT_CONFIG_DIR}/.session-test" 2>/dev/null; then
    rm -f "$HOME/${AGENT_CONFIG_DIR}/.session-test"
    pass "session data dir writable"
else
    fail "session data dir not writable (sessions will be lost)"
fi

# ── Agent CLI ─────────────────────────────────────────────────────────

section "Agent CLI ($AGENT)"

case "$AGENT" in
    copilot)
        if command -v copilot &>/dev/null; then
            version=$(copilot --version 2>/dev/null || echo "unknown")
            pass "copilot ($version)"
            mcp_output=$(copilot mcp list 2>&1) || true
            if echo "$mcp_output" | grep -q "context7\|sequential-thinking\|playwright\|firecrawl"; then
                registered=$(echo "$mcp_output" | grep -cE "^\s*(context7|sequential-thinking|playwright|firecrawl)" || true)
                pass "copilot mcp list: $registered servers registered"
            else
                warn "copilot mcp list: could not verify MCP servers"
            fi
        else
            fail "copilot not found"
        fi
        ;;
    claude)
        if command -v claude &>/dev/null; then
            version=$(claude --version 2>/dev/null || echo "unknown")
            pass "claude ($version)"
        else
            fail "claude not found"
        fi
        ;;
    codex)
        if command -v codex &>/dev/null; then
            version=$(codex --version 2>/dev/null || echo "unknown")
            pass "codex ($version)"
        else
            fail "codex not found"
        fi
        ;;
esac

# ── Authentication ───────────────────────────────────────────────────

section "Authentication"

case "$AGENT" in
    copilot)
        if [[ -n "${GH_TOKEN:-}" ]]; then
            masked="${GH_TOKEN:0:4}...${GH_TOKEN: -4}"
            pass "GH_TOKEN set ($masked)"
        else
            fail "GH_TOKEN not set (copilot will not authenticate)"
        fi
        ;;
    claude)
        if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
            masked="${ANTHROPIC_API_KEY:0:4}...${ANTHROPIC_API_KEY: -4}"
            pass "ANTHROPIC_API_KEY set ($masked)"
        else
            warn "ANTHROPIC_API_KEY not set (claude will not authenticate)"
        fi
        ;;
    codex)
        if [[ -n "${OPENAI_API_KEY:-}" ]]; then
            masked="${OPENAI_API_KEY:0:4}...${OPENAI_API_KEY: -4}"
            pass "OPENAI_API_KEY set ($masked)"
        else
            warn "OPENAI_API_KEY not set (codex will not authenticate)"
        fi
        ;;
esac

# ── Toolchains ───────────────────────────────────────────────────────

section "Toolchains"

if command -v node &>/dev/null; then
    pass "node $(node --version)"
else
    fail "node not found"
fi

if command -v python3 &>/dev/null; then
    pass "python3 $(python3 --version 2>&1 | awk '{print $2}')"
else
    fail "python3 not found"
fi

if command -v rustc &>/dev/null; then
    pass "rustc $(rustc --version | awk '{print $2}')"
else
    fail "rustc not found"
fi

if command -v gcc &>/dev/null; then
    pass "gcc $(gcc --version | head -1 | grep -oP '\d+\.\d+\.\d+' | head -1)"
else
    fail "gcc not found"
fi

# ── LSP servers ──────────────────────────────────────────────────────

section "LSP servers (9 expected)"

check_bin "typescript-language-server" "/usr/local/bin/typescript-language-server"
check_bin "basedpyright-langserver" "/usr/local/bin/basedpyright-langserver"
check_bin "rust-analyzer" "PATH"
check_bin "clangd" "/usr/bin/clangd"
check_bin "lua-language-server" "/usr/local/bin/lua-language-server"
check_bin "bash-language-server" "/usr/local/bin/bash-language-server"
check_bin "docker-langserver" "/usr/local/bin/docker-langserver"
check_bin "yaml-language-server" "/usr/local/bin/yaml-language-server"
check_bin "vscode-json-language-server" "/usr/local/bin/vscode-json-language-server"

# ── MCP servers ──────────────────────────────────────────────────────

section "MCP servers (4 expected)"

check_bin "context7-mcp" "PATH"
check_bin "mcp-server-sequential-thinking" "PATH"
check_bin "playwright-mcp" "PATH"
check_bin "firecrawl-mcp" "PATH"

# ── Formatters & linters ─────────────────────────────────────────────

section "Formatters & linters"

check_bin "ruff" "PATH"
check_bin "prettier" "PATH"
check_bin "shellcheck" "PATH"

# ── Dev tools ────────────────────────────────────────────────────────

section "Dev tools"

for tool in git jq rg fd just curl make cmake gdb valgrind strace go; do
    check_bin "$tool" "PATH"
done

# ── Document & media tools ───────────────────────────────────────────

section "Document & media tools"

for tool in pdftotext tesseract w3m xmlstarlet pandoc convert sqlite3; do
    check_bin "$tool" "PATH"
done

# ── Git configuration ────────────────────────────────────────────────

section "Git"

git_name=$(git config --get user.name 2>/dev/null || echo "")
git_email=$(git config --get user.email 2>/dev/null || echo "")
if [[ -n "$git_name" && -n "$git_email" ]]; then
    pass "identity: $git_name <$git_email>"
else
    fail "git identity not configured"
fi

if git rev-parse --git-dir &>/dev/null; then
    checkstat=$(git config --get core.checkstat 2>/dev/null || echo "")
    if [[ "$checkstat" == "minimal" ]]; then
        pass "core.checkstat=minimal (reindex protection)"
    else
        warn "core.checkstat not set (entrypoint sets this per-project)"
    fi
    pass "inside git repo: $(git rev-parse --show-toplevel 2>/dev/null)"
else
    warn "not inside a git repo (core.checkstat test skipped)"
fi

# ── MCP server env vars ─────────────────────────────────────────────

section "MCP environment"

[[ -n "${FIRECRAWL_API_KEY:-}" ]] && pass "FIRECRAWL_API_KEY set" || warn "FIRECRAWL_API_KEY not set"

# ── Summary ──────────────────────────────────────────────────────────

printf "\n\033[1m── Summary ──\033[0m\n"
printf "  \033[32m%d passed\033[0m" "$PASS"
[[ $WARN -gt 0 ]] && printf "  \033[33m%d warnings\033[0m" "$WARN"
[[ $FAIL -gt 0 ]] && printf "  \033[31m%d failed\033[0m" "$FAIL"
printf "\n"

exit "$FAIL"
