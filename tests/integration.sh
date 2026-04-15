#!/usr/bin/env bash
# tests/integration.sh: Test suite for aidock.
# Supports: --unit (no container image needed), --integration (needs image), or both (default).
# Run via: just test (all), just test-unit (fast, no image)
# shellcheck disable=SC2046  # word-splitting on engine_userns_flags is intentional
# shellcheck disable=SC2034  # variables used inside conditional blocks appear unused to shellcheck

set -uo pipefail

PASS=0
FAIL=0
: "${PROJECT_NAME:?PROJECT_NAME must be set (run via: just test)}"
IMAGE_NAME="${PROJECT_NAME}"
CONTAINER_HOME="/home/${PROJECT_NAME}"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
LAUNCHER="${SCRIPT_DIR}/aidock"
AGENT="copilot"
AGENT_CONFIG_DIR=".copilot"

# Parse test mode: --unit, --integration, or both (default)
RUN_UNIT=false
RUN_INTEGRATION=false
for arg in "$@"; do
    case "$arg" in
        --unit) RUN_UNIT=true ;;
        --integration) RUN_INTEGRATION=true ;;
        *)
            echo "usage: $0 [--unit] [--integration]" >&2
            exit 1
            ;;
    esac
done
# Default: run both
if ! $RUN_UNIT && ! $RUN_INTEGRATION; then
    RUN_UNIT=true
    RUN_INTEGRATION=true
fi

# Isolate tests from real user config by using a temp XDG_CONFIG_HOME
TEST_TMPDIR="$(mktemp -d)"
export XDG_CONFIG_HOME="${TEST_TMPDIR}"
CONFIG_DIR="${XDG_CONFIG_HOME}/${PROJECT_NAME}"
# shellcheck disable=SC2329,SC2317  # cleanup is invoked by trap
cleanup() { rm -rf "${TEST_TMPDIR}"; }
trap cleanup EXIT

# Provide a fake GH_TOKEN so launcher auth checks pass in the isolated env
export GH_TOKEN="fake-token-for-test"

# ── Container engine setup (integration tests only) ──────────────────

# Detect container engine (same logic as launcher)
if [[ -n "${CONTAINER_ENGINE:-}" ]]; then
    ENGINE="$CONTAINER_ENGINE"
elif command -v podman &>/dev/null; then
    ENGINE="podman"
elif command -v docker &>/dev/null; then
    ENGINE="docker"
elif $RUN_INTEGRATION; then
    echo "error: neither podman nor docker found (required for --integration)" >&2
    exit 1
else
    ENGINE="none"
fi

# Engine-specific user namespace flag
engine_userns_flags() {
    if [[ "$ENGINE" == "podman" ]]; then
        echo "--userns=keep-id"
    else
        echo "--user $(id -u):$(id -g)"
    fi
}

# Default timeout for container operations (seconds)
TIMEOUT=${TEST_TIMEOUT:-30}

pass() {
    printf "  \033[32m✓\033[0m %s\n" "$1"
    PASS=$((PASS + 1))
}
fail() {
    printf "  \033[31m✗\033[0m %s\n" "$1${2:+ -- $2}"
    FAIL=$((FAIL + 1))
}
section() { printf "\n\033[1;36m── %s ──\033[0m\n" "$1"; }

run_in_container() {
    timeout "${TIMEOUT}" "$ENGINE" run --rm $(engine_userns_flags) \
        -v "${CONFIG_DIR}/${AGENT}:${CONTAINER_HOME}/${AGENT_CONFIG_DIR}/:rw" \
        -v "${SCRIPT_DIR}:${SCRIPT_DIR}:rw" \
        -e "HOME=${CONTAINER_HOME}" \
        -e "AGENT=${AGENT}" \
        -e "AGENT_CONFIG_DIR=${AGENT_CONFIG_DIR}" \
        -e "PROJECT_NAME=${PROJECT_NAME}" \
        -e "GH_TOKEN=fake-token-for-test" \
        -w "${SCRIPT_DIR}" \
        "${IMAGE_NAME}" \
        "$@"
}

# Run launcher with timeout; separate build output from healthcheck output.
# Returns only healthcheck output (lines after the last "Building" block).
run_launcher_check() {
    local raw rc
    raw=$(timeout "${TIMEOUT}" "${LAUNCHER}" check 2>&1) && rc=0 || rc=$?
    # If a build triggered, strip everything up to and including the COMMIT line
    if echo "$raw" | grep -q "^Building "; then
        echo "$raw" | sed -n '/^COMMIT /,$ { /^COMMIT /d; p; }'
    else
        echo "$raw"
    fi
    return $rc
}

# ── Preflight (integration only) ─────────────────────────────────────

if $RUN_INTEGRATION; then
    if [[ "$ENGINE" == "podman" ]]; then
        if ! "$ENGINE" image exists "${IMAGE_NAME}" 2>/dev/null; then
            echo "error: image ${IMAGE_NAME} not found, run 'just build' first" >&2
            exit 1
        fi
    else
        if ! "$ENGINE" image inspect "${IMAGE_NAME}" &>/dev/null; then
            echo "error: image ${IMAGE_NAME} not found, run 'just build' first" >&2
            exit 1
        fi
    fi
fi

if $RUN_INTEGRATION; then

    # ── Healthcheck baseline ─────────────────────────────────────────────
    # Skipped on CI: podman --userns=keep-id:uid=0,gid=0 fails on GitHub
    # Actions runners (crun gid_map error).  These tests require the
    # launcher which uses that flag.

    if [[ -z "${CI:-}" ]]; then

        section "Healthcheck baseline"

        check_output=$(run_launcher_check)
        check_exit=$?

        if [[ $check_exit -eq 0 ]]; then
            pass "checkhealth exits 0 (no failures)"
        else
            fail "checkhealth exits $check_exit" "expected 0"
        fi

        fail_count=$(echo "$check_output" | grep -c '✗' || true)
        if [[ $fail_count -eq 0 ]]; then
            pass "checkhealth has 0 failure lines"
        else
            fail "checkhealth has $fail_count failure lines" "expected 0"
        fi

        # ── Output formatting ────────────────────────────────────────────────

        section "Output formatting"

        # gcc version should be a single line with ✓, no stray version numbers
        # Strip ANSI escape codes and carriage returns before matching
        clean_output=$(echo "$check_output" | sed -e 's/\x1b\[[0-9;]*m//g' -e 's/\r$//')
        gcc_lines=$(echo "$clean_output" | grep -A1 "gcc" | head -2)
        gcc_main=$(echo "$gcc_lines" | head -1)
        gcc_next=$(echo "$gcc_lines" | tail -1)

        if echo "$gcc_main" | grep -qP 'gcc \d+\.\d+\.\d+$'; then
            pass "gcc output is single clean line"
        else
            fail "gcc output malformed" "got: $gcc_main"
        fi

        if echo "$gcc_next" | grep -qP '^\d+\.\d+\.\d+$'; then
            fail "stray version line after gcc" "got: $gcc_next"
        else
            pass "no stray version line after gcc"
        fi

    else
        section "Healthcheck / Output / Auto-rebuild (skipped on CI)"
        pass "skipped: podman userns uid=0,gid=0 unsupported on CI runners"
    fi # end CI skip

    # ── Session data persistence ─────────────────────────────────────────

    section "Session data persistence"

    sentinel="test-sentinel-$(date +%s)"
    agent_data_dir="${CONFIG_DIR}/${AGENT}"
    mkdir -p "${agent_data_dir}"

    # Write a file into the session dir
    run_in_container bash -c "echo '${sentinel}' > ${CONTAINER_HOME}/${AGENT_CONFIG_DIR}/.persistence-test"
    write_exit=$?

    if [[ $write_exit -eq 0 ]]; then
        pass "write sentinel to session dir"
    else
        fail "write sentinel to session dir" "exit $write_exit"
    fi

    # Read it back in a NEW container (must persist across --rm containers)
    readback=$(run_in_container cat "${CONTAINER_HOME}/${AGENT_CONFIG_DIR}/.persistence-test" 2>/dev/null || echo "")

    if [[ "$readback" == "$sentinel" ]]; then
        pass "sentinel persists across container runs"
    else
        fail "sentinel lost after container restart" "expected '$sentinel', got '$readback'"
    fi

    # Clean up
    run_in_container rm -f "${CONTAINER_HOME}/${AGENT_CONFIG_DIR}/.persistence-test" 2>/dev/null || true

    # ── Symlink re-creation ──────────────────────────────────────────────

    section "Symlink idempotency"

    # The entrypoint creates symlinks in the session dir. Running twice must not
    # error out (regression: ln -sf on an existing symlink-to-directory follows the
    # link and tries to write inside the read-only target).

    if [[ -d "${HOME}/.copilot/agents" ]]; then
        # First run: entrypoint creates the symlink
        run_in_container \
            bash -c "ls -la ${CONTAINER_HOME}/${AGENT_CONFIG_DIR}/agents 2>&1" \
            >/dev/null 2>&1 || true

        # Second run: entrypoint must handle existing symlink without error
        out2=$(timeout "${TIMEOUT}" "$ENGINE" run --rm $(engine_userns_flags) \
            -v "${CONFIG_DIR}/${AGENT}:${CONTAINER_HOME}/${AGENT_CONFIG_DIR}/:rw" \
            -v "${SCRIPT_DIR}:${SCRIPT_DIR}:rw" \
            -v "${HOME}/.copilot/agents/:${CONTAINER_HOME}/.copilot-agents-host/:ro" \
            -e "HOME=${CONTAINER_HOME}" \
            -e "AGENT=${AGENT}" \
            -e "AGENT_CONFIG_DIR=${AGENT_CONFIG_DIR}" \
            -e "PROJECT_NAME=${PROJECT_NAME}" \
            -e "GH_TOKEN=fake-token-for-test" \
            -w "${SCRIPT_DIR}" \
            "${IMAGE_NAME}" \
            bash -c "echo ok" \
            2>&1)
        exit2=$?

        if [[ $exit2 -eq 0 && "$out2" == "ok" ]]; then
            pass "entrypoint handles existing agent symlink"
        else
            fail "entrypoint fails on second run with agents" "exit=$exit2 out=$out2"
        fi
    else
        pass "agents dir not present on host (symlink test skipped)"
    fi

    # ── Auto-rebuild logic ───────────────────────────────────────────────
    # Also skipped on CI (uses ./aidock check which triggers userns issue)

    if [[ -z "${CI:-}" ]]; then

        section "Auto-rebuild logic"

        # Running the launcher twice should NOT trigger a rebuild the second time.
        # We capture raw output (not filtered) to check for the "Building" message.

        timeout "${TIMEOUT}" "${LAUNCHER}" check >/dev/null 2>&1
        second_raw=$(timeout "${TIMEOUT}" "${LAUNCHER}" check 2>&1)

        if echo "$second_raw" | grep -q "Building ${IMAGE_NAME}"; then
            fail "unnecessary rebuild on second run" "saw 'Building' message"
        else
            pass "no rebuild on second invocation"
        fi

        # config.json changes should trigger a rebuild (configs are baked in)
        # The launcher checks BUILD_DIR (= CONFIG_DIR), not SCRIPT_DIR
        rebuild_cfg="${CONFIG_DIR}/agents/copilot/config.json"
        orig_ts=$(stat -c %Y "${rebuild_cfg}")
        cp "${rebuild_cfg}" "${rebuild_cfg}.bak"
        sleep 1
        touch "${rebuild_cfg}"

        rebuild_raw=$(timeout "${TIMEOUT}" "${LAUNCHER}" check 2>&1)
        if echo "$rebuild_raw" | grep -q "Building ${IMAGE_NAME}"; then
            pass "config.json change triggers rebuild (configs baked in)"
        else
            fail "config.json change did not trigger rebuild" "expected 'Building' message"
        fi

        # Restore config.json with its original timestamp so later tests don't trigger rebuilds
        mv "${rebuild_cfg}.bak" "${rebuild_cfg}"
        touch -d "@${orig_ts}" "${rebuild_cfg}"

    fi # end CI skip (auto-rebuild)

    # ── Config assembly (entrypoint) ─────────────────────────────────────

    section "Config assembly"

    # Verify entrypoint copies baked-in defaults to agent config dir
    config_model=$(run_in_container jq -r '.model' "${CONTAINER_HOME}/${AGENT_CONFIG_DIR}/config.json" 2>/dev/null || echo "")
    if [[ -n "$config_model" && "$config_model" != "null" ]]; then
        pass "config.json assembled from defaults (model=$config_model)"
    else
        fail "config.json not assembled from defaults" "got model=$config_model"
    fi

    lsp_check=$(run_in_container jq -r 'keys[0]' "${CONTAINER_HOME}/${AGENT_CONFIG_DIR}/lsp-config.json" 2>/dev/null || echo "")
    if [[ -n "$lsp_check" && "$lsp_check" != "null" ]]; then
        pass "lsp-config.json assembled from defaults"
    else
        fail "lsp-config.json not assembled from defaults" "got: $lsp_check"
    fi

    mcp_check=$(run_in_container jq -r '.mcpServers | keys[0]' "${CONTAINER_HOME}/${AGENT_CONFIG_DIR}/mcp-config.json" 2>/dev/null || echo "")
    if [[ -n "$mcp_check" && "$mcp_check" != "null" ]]; then
        pass "mcp-config.json assembled from defaults"
    else
        fail "mcp-config.json not assembled from defaults" "got: $mcp_check"
    fi

    # ── Config persistence ────────────────────────────────────────────────

    section "Config persistence"

    # Verify defaults are seeded on first run, then modifications persist
    persist_dir=$(mktemp -d)

    # First run: config should be seeded from defaults
    first_model=$(timeout "${TIMEOUT}" "$ENGINE" run --rm $(engine_userns_flags) \
        -v "${persist_dir}:${CONTAINER_HOME}/${AGENT_CONFIG_DIR}/:rw" \
        -v "${SCRIPT_DIR}:${SCRIPT_DIR}:rw" \
        -e "HOME=${CONTAINER_HOME}" \
        -e "AGENT=${AGENT}" \
        -e "AGENT_CONFIG_DIR=${AGENT_CONFIG_DIR}" \
        -e "PROJECT_NAME=${PROJECT_NAME}" \
        -e "GH_TOKEN=fake-token-for-test" \
        -w "${SCRIPT_DIR}" \
        "${IMAGE_NAME}" \
        jq -r '.model' "${CONTAINER_HOME}/${AGENT_CONFIG_DIR}/config.json" 2>/dev/null || echo "")

    if [[ -n "$first_model" && "$first_model" != "null" ]]; then
        pass "default config seeded on first run"
    else
        fail "default config not seeded" "got '$first_model'"
    fi

    # Simulate agent modifying config on the host (persisted data dir)
    jq '.model = "user-modified-model"' "${persist_dir}/config.json" >"${persist_dir}/config.json.tmp" &&
        mv "${persist_dir}/config.json.tmp" "${persist_dir}/config.json"

    # Second run: modified config should survive (cp -n = no clobber)
    second_model=$(timeout "${TIMEOUT}" "$ENGINE" run --rm $(engine_userns_flags) \
        -v "${persist_dir}:${CONTAINER_HOME}/${AGENT_CONFIG_DIR}/:rw" \
        -v "${SCRIPT_DIR}:${SCRIPT_DIR}:rw" \
        -e "HOME=${CONTAINER_HOME}" \
        -e "AGENT=${AGENT}" \
        -e "AGENT_CONFIG_DIR=${AGENT_CONFIG_DIR}" \
        -e "PROJECT_NAME=${PROJECT_NAME}" \
        -e "GH_TOKEN=fake-token-for-test" \
        -w "${SCRIPT_DIR}" \
        "${IMAGE_NAME}" \
        jq -r '.model' "${CONTAINER_HOME}/${AGENT_CONFIG_DIR}/config.json" 2>/dev/null || echo "")

    if [[ "$second_model" == "user-modified-model" ]]; then
        pass "modified config persists across runs (no clobber)"
    else
        fail "modified config was overwritten" "expected 'user-modified-model', got '$second_model'"
    fi

    rm -rf "${persist_dir}"

    # ── Per-agent binary checks ──────────────────────────────────────────

    section "Per-agent binary checks"

    for test_agent in copilot claude codex; do
        mkdir -p "${CONFIG_DIR}/${test_agent}"
        agent_check=$(timeout "${TIMEOUT}" "$ENGINE" run --rm $(engine_userns_flags) \
            -v "${CONFIG_DIR}/${test_agent}:${CONTAINER_HOME}/.${test_agent}/:rw" \
            -v "${SCRIPT_DIR}:${SCRIPT_DIR}:rw" \
            -e "HOME=${CONTAINER_HOME}" \
            -e "AGENT=${test_agent}" \
            -e "AGENT_CONFIG_DIR=.${test_agent}" \
            -e "PROJECT_NAME=${PROJECT_NAME}" \
            -e "GH_TOKEN=fake-token-for-test" \
            -w "${SCRIPT_DIR}" \
            "${IMAGE_NAME}" \
            bash -c "command -v ${test_agent} && echo FOUND" 2>/dev/null || echo "")

        if echo "$agent_check" | grep -q "FOUND"; then
            pass "${test_agent} binary installed"
        else
            fail "${test_agent} binary not found" "agent not installed in image"
        fi
    done

    # ── Claude config assembly ───────────────────────────────────────────

    section "Claude config assembly"

    claude_data_dir="${CONFIG_DIR}/claude"
    mkdir -p "${claude_data_dir}"

    claude_settings=$(timeout "${TIMEOUT}" "$ENGINE" run --rm $(engine_userns_flags) \
        -v "${claude_data_dir}:${CONTAINER_HOME}/.claude/:rw" \
        -v "${SCRIPT_DIR}:${SCRIPT_DIR}:rw" \
        -e "HOME=${CONTAINER_HOME}" \
        -e "AGENT=claude" \
        -e "AGENT_CONFIG_DIR=.claude" \
        -e "PROJECT_NAME=${PROJECT_NAME}" \
        -w "${SCRIPT_DIR}" \
        "${IMAGE_NAME}" \
        jq -r '.permissions' "${CONTAINER_HOME}/.claude/settings.json" 2>/dev/null || echo "")

    if [[ -n "$claude_settings" && "$claude_settings" != "null" ]]; then
        pass "claude settings.json assembled from defaults"
    else
        fail "claude settings.json not assembled" "got: $claude_settings"
    fi

    claude_mcp=$(timeout "${TIMEOUT}" "$ENGINE" run --rm $(engine_userns_flags) \
        -v "${claude_data_dir}:${CONTAINER_HOME}/.claude/:rw" \
        -v "${SCRIPT_DIR}:${SCRIPT_DIR}:rw" \
        -e "HOME=${CONTAINER_HOME}" \
        -e "AGENT=claude" \
        -e "AGENT_CONFIG_DIR=.claude" \
        -e "PROJECT_NAME=${PROJECT_NAME}" \
        -w "${SCRIPT_DIR}" \
        "${IMAGE_NAME}" \
        jq -r '.mcpServers | keys[0]' "${CONTAINER_HOME}/.claude/mcp-config.json" 2>/dev/null || echo "")

    if [[ -n "$claude_mcp" && "$claude_mcp" != "null" ]]; then
        pass "claude mcp-config.json assembled from defaults"
    else
        fail "claude mcp-config.json not assembled" "got: $claude_mcp"
    fi

    # ── Codex config assembly ────────────────────────────────────────────

    section "Codex config assembly"

    codex_data_dir="${CONFIG_DIR}/codex"
    mkdir -p "${codex_data_dir}"

    codex_config=$(timeout "${TIMEOUT}" "$ENGINE" run --rm $(engine_userns_flags) \
        -v "${codex_data_dir}:${CONTAINER_HOME}/.codex/:rw" \
        -v "${SCRIPT_DIR}:${SCRIPT_DIR}:rw" \
        -e "HOME=${CONTAINER_HOME}" \
        -e "AGENT=codex" \
        -e "AGENT_CONFIG_DIR=.codex" \
        -e "PROJECT_NAME=${PROJECT_NAME}" \
        -w "${SCRIPT_DIR}" \
        "${IMAGE_NAME}" \
        bash -c "cat ${CONTAINER_HOME}/.codex/config.toml" 2>/dev/null || echo "")

    if echo "$codex_config" | grep -q "approval_policy"; then
        pass "codex config.toml assembled from defaults"
    else
        fail "codex config.toml not assembled" "got: $codex_config"
    fi

    # ── Per-agent auth warnings ──────────────────────────────────────────

    section "Per-agent auth (checkhealth)"

    # Claude without ANTHROPIC_API_KEY should warn, not fail
    claude_auth_output=$(timeout "${TIMEOUT}" "$ENGINE" run --rm $(engine_userns_flags) \
        -v "${claude_data_dir}:${CONTAINER_HOME}/.claude/:rw" \
        -v "${SCRIPT_DIR}:${SCRIPT_DIR}:rw" \
        -e "HOME=${CONTAINER_HOME}" \
        -e "AGENT=claude" \
        -e "AGENT_CONFIG_DIR=.claude" \
        -e "PROJECT_NAME=${PROJECT_NAME}" \
        -w "${SCRIPT_DIR}" \
        "${IMAGE_NAME}" \
        checkhealth.sh 2>&1 || true)

    if echo "$claude_auth_output" | grep -q "ANTHROPIC_API_KEY not set"; then
        pass "claude auth warning shown when key missing"
    else
        fail "claude auth warning not shown" "expected ANTHROPIC_API_KEY warning"
    fi

    # Codex without OPENAI_API_KEY should warn, not fail
    codex_auth_output=$(timeout "${TIMEOUT}" "$ENGINE" run --rm $(engine_userns_flags) \
        -v "${codex_data_dir}:${CONTAINER_HOME}/.codex/:rw" \
        -v "${SCRIPT_DIR}:${SCRIPT_DIR}:rw" \
        -e "HOME=${CONTAINER_HOME}" \
        -e "AGENT=codex" \
        -e "AGENT_CONFIG_DIR=.codex" \
        -e "PROJECT_NAME=${PROJECT_NAME}" \
        -w "${SCRIPT_DIR}" \
        "${IMAGE_NAME}" \
        checkhealth.sh 2>&1 || true)

    if echo "$codex_auth_output" | grep -q "OPENAI_API_KEY not set"; then
        pass "codex auth warning shown when key missing"
    else
        fail "codex auth warning not shown" "expected OPENAI_API_KEY warning"
    fi

fi # end $RUN_INTEGRATION

if $RUN_UNIT; then

    # ── CLI flags ─────────────────────────────────────────────────────────

    section "CLI flags"

    # --info shows diagnostics
    info_output=$(timeout "${TIMEOUT}" "${LAUNCHER}" info --no-rebuild 2>&1)
    if echo "$info_output" | grep -q "^Engine:" && echo "$info_output" | grep -q "^Agent:"; then
        pass "info shows engine and agent"
    else
        fail "info shows engine and agent" "got: $info_output"
    fi

    # --dry-run prints command without executing
    dry_output=$(timeout "${TIMEOUT}" "${LAUNCHER}" run --dry-run --no-rebuild 2>&1)
    if echo "$dry_output" | grep -q "$ENGINE.*run.*${IMAGE_NAME}"; then
        pass "run --dry-run prints container command"
    else
        fail "run --dry-run prints container command" "got: $dry_output"
    fi

    # --dry-run redacts secrets
    if echo "$dry_output" | grep -q 'GH_TOKEN=\*\*\*REDACTED\*\*\*'; then
        pass "run --dry-run redacts auth tokens"
    else
        fail "run --dry-run redacts auth tokens" "got: $(echo "$dry_output" | grep -o 'GH_TOKEN=[^ ]*')"
    fi

    # NO_UPDATE_NOTIFIER is set to suppress ephemeral update prompts
    if echo "$dry_output" | grep -q 'NO_UPDATE_NOTIFIER=1'; then
        pass "run sets NO_UPDATE_NOTIFIER=1"
    else
        fail "run sets NO_UPDATE_NOTIFIER=1" "not found in dry-run output"
    fi

    # Unknown option is rejected
    excl_output=$(timeout "${TIMEOUT}" "${LAUNCHER}" run --bogus 2>&1 || true)
    if echo "$excl_output" | grep -q "unknown option"; then
        pass "unknown option rejected"
    else
        fail "unknown option rejected" "expected error, got: $excl_output"
    fi

    # --no-cache only valid with build command
    build_excl=$(timeout "${TIMEOUT}" "${LAUNCHER}" run --no-cache 2>&1 || true)
    if echo "$build_excl" | grep -q "only valid with"; then
        pass "--no-cache rejected outside build"
    else
        fail "--no-cache rejected outside build" "expected error, got: $build_excl"
    fi

    # reset -a on nonexistent agent dir creates it and seeds defaults
    rm -rf "${CONFIG_DIR}/codex" # ensure clean state
    reset_output=$(timeout "${TIMEOUT}" "${LAUNCHER}" reset --agent codex 2>&1)
    if echo "$reset_output" | grep -qi "Reset codex config"; then
        pass "reset creates and seeds missing agent dir"
    else
        fail "reset creates and seeds missing agent dir" "got: $reset_output"
    fi

    # reset -a on existing agent dir re-seeds config but preserves other files
    reset_test_dir="${CONFIG_DIR}/codex"
    mkdir -p "$reset_test_dir"
    touch "$reset_test_dir/session-sentinel"
    reset_reseed_output=$(timeout "${TIMEOUT}" "${LAUNCHER}" reset --agent codex 2>&1)
    if [[ -f "$reset_test_dir/session-sentinel" ]] && echo "$reset_reseed_output" | grep -q "session data preserved"; then
        pass "reset preserves session data"
    else
        fail "reset preserves session data" "sentinel missing or wrong output: $reset_reseed_output"
    fi

    # reset --purge -a --force deletes agent dir entirely
    reset_purge_output=$(timeout "${TIMEOUT}" "${LAUNCHER}" reset --purge --force --agent codex 2>&1)
    if [[ ! -d "$reset_test_dir" ]] && echo "$reset_purge_output" | grep -q "Purged"; then
        pass "reset --purge deletes agent dir"
    else
        fail "reset --purge deletes agent dir" "dir still exists or wrong output: $reset_purge_output"
    fi

    # --purge rejected outside reset
    _purge_out=$(timeout "${TIMEOUT}" "${LAUNCHER}" build --purge 2>&1)
    _purge_rc=$?
    if echo "$_purge_out" | grep -q "error.*--purge"; then
        pass "--purge rejected outside reset"
    else
        fail "--purge rejected outside reset" "rc=$_purge_rc out=[$_purge_out]"
    fi

    # ── Build / Update / Clean modes ─────────────────────────────────────

    section "Build / Update / Clean modes"

    # --build --dry-run shows the build command without executing
    build_dry=$(timeout "${TIMEOUT}" "${LAUNCHER}" build --dry-run 2>&1)
    if echo "$build_dry" | grep -q "\[dry-run\].*build.*PROJECT_NAME"; then
        pass "build --dry-run shows build command"
    else
        fail "build --dry-run shows build command" "got: $build_dry"
    fi

    # build --no-cache --dry-run includes --no-cache
    build_rebuild_dry=$(timeout "${TIMEOUT}" "${LAUNCHER}" build --no-cache --dry-run 2>&1)
    if echo "$build_rebuild_dry" | grep -q "\-\-no-cache"; then
        pass "build --no-cache adds --no-cache flag"
    else
        fail "build --no-cache adds --no-cache flag" "got: $build_rebuild_dry"
    fi

    # --update --dry-run shows pull + no-cache
    update_dry=$(timeout "${TIMEOUT}" "${LAUNCHER}" update --dry-run 2>&1)
    if echo "$update_dry" | grep -q "\-\-pull" && echo "$update_dry" | grep -q "\-\-no-cache"; then
        pass "update --dry-run shows pull + no-cache"
    else
        fail "update --dry-run shows pull + no-cache" "got: $update_dry"
    fi

    # update-agents --dry-run shows AGENT_CACHE_BUST without --pull/--no-cache
    update_agents_dry=$(timeout "${TIMEOUT}" "${LAUNCHER}" update-agents --dry-run 2>&1)
    if echo "$update_agents_dry" | grep -q "AGENT_CACHE_BUST"; then
        pass "update-agents --dry-run shows AGENT_CACHE_BUST"
    else
        fail "update-agents --dry-run shows AGENT_CACHE_BUST" "got: $update_agents_dry"
    fi
    if echo "$update_agents_dry" | grep -q "\-\-pull\|\-\-no-cache"; then
        fail "update-agents should not use --pull or --no-cache"
    else
        pass "update-agents does not use --pull or --no-cache"
    fi

    # --clean --dry-run shows what would be cleaned
    clean_dry=$(timeout "${TIMEOUT}" "${LAUNCHER}" clean --dry-run 2>&1)
    if echo "$clean_dry" | grep -q "\[dry-run\].*rmi"; then
        pass "clean --dry-run shows rmi command"
    else
        fail "clean --dry-run shows rmi command" "got: $clean_dry"
    fi

    # --version shows version string
    version_output=$(timeout "${TIMEOUT}" "${LAUNCHER}" --version 2>&1)
    if echo "$version_output" | grep -qE "^${PROJECT_NAME} [0-9]+\.[0-9]+"; then
        pass "--version shows version"
    else
        fail "--version shows version" "got: $version_output"
    fi

    # ── Diff mode ────────────────────────────────────────────────────────

    section "Diff mode"

    # --diff with no drift returns 0 and says "no drift"
    # First, seed config by running the launcher
    timeout "${TIMEOUT}" "${LAUNCHER}" run --dry-run --no-rebuild >/dev/null 2>&1
    # Then reset to get fresh defaults
    timeout "${TIMEOUT}" "${LAUNCHER}" reset >/dev/null 2>&1
    timeout "${TIMEOUT}" "${LAUNCHER}" run --dry-run --no-rebuild >/dev/null 2>&1
    diff_clean=$(timeout "${TIMEOUT}" "${LAUNCHER}" diff 2>&1)
    diff_rc=$?
    if [[ $diff_rc -eq 0 ]] && echo "$diff_clean" | grep -qi "no drift"; then
        pass "diff with no drift returns 0"
    else
        fail "diff with no drift returns 0" "rc=$diff_rc, got: $diff_clean"
    fi

    # --diff detects modification and returns 1
    echo "# user edit" >>"${CONFIG_DIR}/Containerfile"
    diff_modified=$(timeout "${TIMEOUT}" "${LAUNCHER}" diff 2>&1)
    diff_mod_rc=$?
    sed -i '/# user edit/d' "${CONFIG_DIR}/Containerfile"
    if [[ $diff_mod_rc -eq 1 ]] && echo "$diff_modified" | grep -q "user edit"; then
        pass "diff detects modification (exit 1)"
    else
        fail "diff detects modification (exit 1)" "rc=$diff_mod_rc, got: $diff_modified"
    fi

    # --diff --agent scopes to agent config
    # Clean and seed agent config from defaults so there's no drift
    rm -rf "${CONFIG_DIR}/copilot"
    mkdir -p "${CONFIG_DIR}/copilot"
    cp "${SCRIPT_DIR}/defaults/agents/copilot/"* "${CONFIG_DIR}/copilot/"
    diff_agent=$(timeout "${TIMEOUT}" "${LAUNCHER}" diff --agent copilot 2>&1)
    diff_agent_rc=$?
    if [[ $diff_agent_rc -eq 0 ]] && echo "$diff_agent" | grep -qi "no drift"; then
        pass "diff --agent scopes to agent"
    else
        fail "diff --agent scopes to agent" "rc=$diff_agent_rc, got: $diff_agent"
    fi

    # ── Default agent preference ─────────────────────────────────────────

    section "Default agent preference"

    # default-agent file changes the agent
    echo "claude" >"${CONFIG_DIR}/default-agent"
    default_dry=$(timeout "${TIMEOUT}" "${LAUNCHER}" run --dry-run --no-rebuild 2>&1)
    rm -f "${CONFIG_DIR}/default-agent"
    if echo "$default_dry" | grep -q "AGENT=claude"; then
        pass "default-agent file selects claude"
    else
        fail "default-agent file selects claude" "got: $(echo "$default_dry" | grep -o 'AGENT=[^ ]*')"
    fi

    # --agent overrides default-agent file
    echo "claude" >"${CONFIG_DIR}/default-agent"
    override_dry=$(timeout "${TIMEOUT}" "${LAUNCHER}" run --dry-run --no-rebuild --agent copilot 2>&1)
    rm -f "${CONFIG_DIR}/default-agent"
    if echo "$override_dry" | grep -q "AGENT=copilot"; then
        pass "--agent overrides default-agent file"
    else
        fail "--agent overrides default-agent file" "got: $(echo "$override_dry" | grep -o 'AGENT=[^ ]*')"
    fi

    # Invalid default-agent file is caught
    echo "invalid-agent" >"${CONFIG_DIR}/default-agent"
    invalid_output=$(timeout "${TIMEOUT}" "${LAUNCHER}" run --dry-run --no-rebuild 2>&1 || true)
    rm -f "${CONFIG_DIR}/default-agent"
    if echo "$invalid_output" | grep -q "unknown agent"; then
        pass "invalid default-agent file caught"
    else
        fail "invalid default-agent file caught" "got: $invalid_output"
    fi

    # ── First-run message ────────────────────────────────────────────────

    section "First-run message"

    # First run for an agent that has no config dir should show message
    first_run_dir="${CONFIG_DIR}/codex"
    rm -rf "$first_run_dir"
    first_run_output=$(timeout "${TIMEOUT}" "${LAUNCHER}" run --dry-run --no-rebuild --agent codex 2>&1)
    if echo "$first_run_output" | grep -q "First run for codex"; then
        pass "first-run message shown for new agent"
    else
        fail "first-run message shown for new agent" "got: $first_run_output"
    fi

    # Subsequent run with existing dir should NOT show first-run message
    mkdir -p "$first_run_dir"
    second_run_output=$(timeout "${TIMEOUT}" "${LAUNCHER}" run --dry-run --no-rebuild --agent codex 2>&1)
    rm -rf "$first_run_dir"
    if ! echo "$second_run_output" | grep -q "First run for"; then
        pass "no first-run message on subsequent run"
    else
        fail "no first-run message on subsequent run" "got: $second_run_output"
    fi

    # ── Containerfile seeding ────────────────────────────────────────────

    section "Containerfile seeding"

    # Containerfile should be seeded to CONFIG_DIR on run
    if [[ -f "${CONFIG_DIR}/Containerfile" ]]; then
        pass "Containerfile seeded to config dir"
    else
        fail "Containerfile seeded to config dir" "not found at ${CONFIG_DIR}/Containerfile"
    fi

    # Support files should be seeded too
    if [[ -f "${CONFIG_DIR}/init-home.sh" ]] && [[ -f "${CONFIG_DIR}/checkhealth.sh" ]]; then
        pass "support files seeded to config dir"
    else
        fail "support files seeded to config dir" "init-home.sh or checkhealth.sh missing"
    fi

    # Agent default configs should be seeded
    if [[ -d "${CONFIG_DIR}/agents/copilot" ]]; then
        pass "agent defaults seeded to config dir"
    else
        fail "agent defaults seeded to config dir" "agents/copilot/ missing"
    fi

    # User edits to Containerfile should be preserved on re-run
    echo "# user customization" >>"${CONFIG_DIR}/Containerfile"
    timeout "${TIMEOUT}" "${LAUNCHER}" run --dry-run --no-rebuild >/dev/null 2>&1
    if grep -q "# user customization" "${CONFIG_DIR}/Containerfile"; then
        pass "user edits to Containerfile preserved"
    else
        fail "user edits to Containerfile preserved" "customization line missing after re-run"
    fi
    # Clean up the edit
    sed -i '/# user customization/d' "${CONFIG_DIR}/Containerfile"

    # reset (without -a) should overwrite build files with defaults
    echo "# user customization for reset test" >>"${CONFIG_DIR}/Containerfile"
    timeout "${TIMEOUT}" "${LAUNCHER}" reset >/dev/null 2>&1
    if [[ -f "${CONFIG_DIR}/Containerfile" ]] && ! grep -q "# user customization for reset test" "${CONFIG_DIR}/Containerfile"; then
        pass "reset overwrites build files with defaults"
    else
        fail "reset overwrites build files with defaults" "customization still present or Containerfile missing"
    fi

    # .last-build should be removed (triggers rebuild)
    if [[ ! -f "${CONFIG_DIR}/.last-build" ]]; then
        pass "reset removes .last-build marker"
    else
        fail "reset removes .last-build marker"
    fi

    # Build files should still exist (overwritten, not deleted)
    if [[ -f "${CONFIG_DIR}/Containerfile" ]] && [[ -d "${CONFIG_DIR}/agents" ]]; then
        pass "build files present after reset"
    else
        fail "build files present after reset" "Containerfile or agents/ missing"
    fi

    # --info should show Containerfile path
    info_output=$(timeout "${TIMEOUT}" "${LAUNCHER}" info 2>&1)
    if echo "$info_output" | grep -q "Containerfile:"; then
        pass "info shows Containerfile path"
    else
        fail "info shows Containerfile path" "got: $info_output"
    fi

    section "Installed artifact (dist smoke test)"

    # Copy dist script to isolated dir — no adjacent repo files
    smoke_dir=$(mktemp -d)
    smoke_cfg=$(mktemp -d)
    cp "${LAUNCHER}" "${smoke_dir}/aidock"
    chmod +x "${smoke_dir}/aidock"

    # Seeding works from embedded assets
    smoke_dry=$(XDG_CONFIG_HOME="$smoke_cfg" GH_TOKEN=fake timeout "${TIMEOUT}" "${smoke_dir}/aidock" --dry-run 2>&1 || true)
    if [[ -f "${smoke_cfg}/aidock/Containerfile" ]]; then
        pass "dist seeds Containerfile without repo"
    else
        fail "dist seeds Containerfile without repo" "file not found after dry-run"
    fi

    # --diff works from embedded assets
    smoke_diff=$(XDG_CONFIG_HOME="$smoke_cfg" GH_TOKEN=fake timeout "${TIMEOUT}" "${smoke_dir}/aidock" diff 2>&1)
    smoke_diff_rc=$?
    if [[ $smoke_diff_rc -eq 0 ]] && echo "$smoke_diff" | grep -q "No drift"; then
        pass "dist --diff works without repo"
    else
        fail "dist --diff works without repo" "rc=${smoke_diff_rc}, got: $smoke_diff"
    fi

    rm -rf "$smoke_dir" "$smoke_cfg"

fi # end $RUN_UNIT

# ── Summary ──────────────────────────────────────────────────────────

printf "\n\033[1m── Test summary ──\033[0m\n"
printf "  \033[32m%d passed\033[0m" "$PASS"
[[ $FAIL -gt 0 ]] && printf "  \033[31m%d failed\033[0m" "$FAIL"
printf "\n"

exit "$FAIL"
