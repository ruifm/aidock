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
IMAGE_NAME="${PROJECT_NAME}-base"
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

# Provide fake auth env vars so probe_agent_auth passes in the isolated env
export GH_TOKEN="fake-token-for-test"
export ANTHROPIC_API_KEY="fake-anthropic-key-for-test"
export OPENAI_API_KEY="fake-openai-key-for-test"

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
    dry_output=$(timeout "${TIMEOUT}" "${LAUNCHER}" run --dry-run --no-rebuild --agent copilot 2>&1)
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

    # run dry-run no longer includes --rm (commit-on-exit owns lifecycle)
    if echo "$dry_output" | grep -q -- '--rm'; then
        fail "run --dry-run omits --rm" "got: $dry_output"
    else
        pass "run --dry-run omits --rm"
    fi

    # run dry-run advertises commit_on_exit policy
    if echo "$dry_output" | grep -q '\[dry-run\] commit_on_exit='; then
        pass "run --dry-run shows commit policy hint"
    else
        fail "run --dry-run shows commit policy hint" "got: $dry_output"
    fi

    # run dry-run shows the per-session lockfile path
    if echo "$dry_output" | grep -q 'session_lock=.*sessions/[0-9a-f]\+\.lock'; then
        pass "run --dry-run shows session lock path"
    else
        fail "run --dry-run shows session lock path" "got: $dry_output"
    fi

    # check dry-run keeps --rm (ephemeral, no commit)
    check_dry=$(timeout "${TIMEOUT}" "${LAUNCHER}" check --dry-run --no-rebuild 2>&1 || true)
    if echo "$check_dry" | grep -q -- '--rm'; then
        pass "check --dry-run keeps --rm"
    else
        fail "check --dry-run keeps --rm" "got: $check_dry"
    fi

    if echo "$check_dry" | grep -q '\[dry-run\] commit_on_exit='; then
        fail "check --dry-run does not advertise commit" "got: $check_dry"
    else
        pass "check --dry-run does not advertise commit"
    fi

    # NO_UPDATE_NOTIFIER / COPILOT_AUTO_UPDATE were dropped along with
    # ephemeral drift detection: agent self-updates now persist via the
    # per-CWD session image commit on exit.

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

    # reset --purge -a --force deletes agent dir entirely
    mkdir -p "${CONFIG_DIR}/codex"
    touch "${CONFIG_DIR}/codex/sentinel"
    reset_purge_output=$(timeout "${TIMEOUT}" "${LAUNCHER}" reset --purge --force --agent codex 2>&1)
    if [[ ! -d "${CONFIG_DIR}/codex" ]] && echo "$reset_purge_output" | grep -q "Purged"; then
        pass "reset --purge deletes agent dir"
    else
        fail "reset --purge deletes agent dir" "dir still exists or wrong output: $reset_purge_output"
    fi

    # reset --agent without --purge is rejected (no defaults to restore)
    reset_noseed_output=$(timeout "${TIMEOUT}" "${LAUNCHER}" reset --agent codex 2>&1 || true)
    if echo "$reset_noseed_output" | grep -q "requires --purge"; then
        pass "reset --agent without --purge rejected"
    else
        fail "reset --agent without --purge rejected" "got: $reset_noseed_output"
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

    # ── Agent auth probe (Phase H) ──────────────────────────────────────

    section "Agent auth probe"

    # Explicit -a with no host auth dies with the agent's setup hint.
    saved_anthropic="${ANTHROPIC_API_KEY:-}"
    unset ANTHROPIC_API_KEY
    no_auth_output=$(env -u ANTHROPIC_API_KEY HOME="${TEST_TMPDIR}" \
        timeout "${TIMEOUT}" "${LAUNCHER}" run --dry-run --no-rebuild --agent claude 2>&1 || true)
    if echo "$no_auth_output" | grep -q "agent 'claude' is not configured"; then
        pass "explicit -a without host auth dies (run mode)"
    else
        fail "explicit -a without host auth dies (run mode)" "got: $no_auth_output"
    fi
    if echo "$no_auth_output" | grep -q "ANTHROPIC_API_KEY"; then
        pass "explicit -a without host auth shows setup hint"
    else
        fail "explicit -a without host auth shows setup hint" "got: $no_auth_output"
    fi

    # shell mode warns instead of dying.
    shell_output=$(env -u ANTHROPIC_API_KEY HOME="${TEST_TMPDIR}" \
        timeout "${TIMEOUT}" "${LAUNCHER}" shell --dry-run --no-rebuild --agent claude 2>&1 || true)
    if echo "$shell_output" | grep -q "warning: agent 'claude' has no host auth"; then
        pass "shell mode warns when explicit agent unconfigured"
    else
        fail "shell mode warns when explicit agent unconfigured" "got: $shell_output"
    fi
    if echo "$shell_output" | grep -q "AGENT=claude"; then
        pass "shell mode continues despite missing auth"
    else
        fail "shell mode continues despite missing auth" "got: $shell_output"
    fi

    # default-agent file unconfigured → also dies in run mode.
    echo "claude" >"${CONFIG_DIR}/default-agent"
    file_no_auth=$(env -u ANTHROPIC_API_KEY HOME="${TEST_TMPDIR}" \
        timeout "${TIMEOUT}" "${LAUNCHER}" run --dry-run --no-rebuild 2>&1 || true)
    rm -f "${CONFIG_DIR}/default-agent"
    if echo "$file_no_auth" | grep -q "agent 'claude' is not configured"; then
        pass "default-agent file with no auth dies"
    else
        fail "default-agent file with no auth dies" "got: $file_no_auth"
    fi

    # Restore env for subsequent tests.
    if [[ -n "$saved_anthropic" ]]; then
        export ANTHROPIC_API_KEY="$saved_anthropic"
    fi

    # ── Agent picker (Phase H) ──────────────────────────────────────────

    section "Agent picker"

    # Zero configured: run mode dies with all hints listed.
    zero_output=$(env -u GH_TOKEN -u ANTHROPIC_API_KEY -u OPENAI_API_KEY \
        HOME="${TEST_TMPDIR}" \
        timeout "${TIMEOUT}" "${LAUNCHER}" run --dry-run --no-rebuild </dev/null 2>&1 || true)
    if echo "$zero_output" | grep -q "no agent is configured"; then
        pass "picker dies when zero agents configured"
    else
        fail "picker dies when zero agents configured" "got: $zero_output"
    fi
    if echo "$zero_output" | grep -q "copilot:" &&
        echo "$zero_output" | grep -q "claude:" &&
        echo "$zero_output" | grep -q "codex:"; then
        pass "picker lists all three setup hints when none configured"
    else
        fail "picker lists all three setup hints when none configured" "got: $zero_output"
    fi

    # One configured: autopick + info message.
    one_output=$(env -u ANTHROPIC_API_KEY -u OPENAI_API_KEY \
        HOME="${TEST_TMPDIR}" \
        timeout "${TIMEOUT}" "${LAUNCHER}" run --dry-run --no-rebuild </dev/null 2>&1 || true)
    if echo "$one_output" | grep -q "autoselected agent: copilot"; then
        pass "picker autopicks the only configured agent"
    else
        fail "picker autopicks the only configured agent" "got: $one_output"
    fi
    if echo "$one_output" | grep -q "AGENT=copilot"; then
        pass "autopicked agent is used for the run"
    else
        fail "autopicked agent is used for the run" "got: $one_output"
    fi

    # 2+ configured, no TTY: dies with hint pointing at -a / default-agent.
    multi_no_tty=$(timeout "${TIMEOUT}" "${LAUNCHER}" run --dry-run --no-rebuild </dev/null 2>&1 || true)
    if echo "$multi_no_tty" | grep -q "multiple agents configured" &&
        echo "$multi_no_tty" | grep -q "no TTY"; then
        pass "picker dies on multi-configured + non-TTY"
    else
        fail "picker dies on multi-configured + non-TTY" "got: $multi_no_tty"
    fi

    # Picker is skipped when --agent is explicit, even with multiple configured.
    explicit_skip=$(timeout "${TIMEOUT}" "${LAUNCHER}" run --dry-run --no-rebuild --agent codex </dev/null 2>&1 || true)
    if echo "$explicit_skip" | grep -q "AGENT=codex" &&
        ! echo "$explicit_skip" | grep -q "multiple agents configured"; then
        pass "picker skipped when --agent is explicit"
    else
        fail "picker skipped when --agent is explicit" "got: $explicit_skip"
    fi

    # Picker is skipped in shell mode (legacy fallback).
    shell_skip=$(timeout "${TIMEOUT}" "${LAUNCHER}" shell --dry-run --no-rebuild </dev/null 2>&1 || true)
    if echo "$shell_skip" | grep -q "AGENT=copilot" &&
        ! echo "$shell_skip" | grep -q "multiple agents configured"; then
        pass "picker skipped in shell mode"
    else
        fail "picker skipped in shell mode" "got: $shell_skip"
    fi

    # ── Session image scheme ─────────────────────────────────────────────

    section "Session image scheme"

    # info should show both base and session image lines, plus session hash
    info_output=$(timeout "${TIMEOUT}" "${LAUNCHER}" info 2>&1)
    if echo "$info_output" | grep -q "Base image:.*${PROJECT_NAME}-base"; then
        pass "info shows base image"
    else
        fail "info shows base image" "got: $info_output"
    fi

    if echo "$info_output" | grep -qE "Session image:.*${PROJECT_NAME}-session-[0-9a-f]{12}"; then
        pass "info shows session image with 12-char hash"
    else
        fail "info shows session image with 12-char hash" "got: $info_output"
    fi

    if echo "$info_output" | grep -qE "Session hash:.*[0-9a-f]{12}"; then
        pass "info shows session hash"
    else
        fail "info shows session hash" "got: $info_output"
    fi

    # Hash must be deterministic for same CWD across two info invocations
    hash1=$(timeout "${TIMEOUT}" "${LAUNCHER}" info 2>&1 | grep -oE "Session hash: +[0-9a-f]{12}" | awk '{print $3}')
    hash2=$(timeout "${TIMEOUT}" "${LAUNCHER}" info 2>&1 | grep -oE "Session hash: +[0-9a-f]{12}" | awk '{print $3}')
    if [[ -n "$hash1" && "$hash1" == "$hash2" ]]; then
        pass "session hash is deterministic for the same CWD"
    else
        fail "session hash is deterministic for the same CWD" "hash1=$hash1 hash2=$hash2"
    fi

    # ── commit_on_exit policy ────────────────────────────────────────────

    section "commit_on_exit policy"

    if [[ -f "${CONFIG_DIR}/aidock.conf" ]]; then
        pass "aidock.conf seeded to config dir"
    else
        fail "aidock.conf seeded to config dir" "not found at ${CONFIG_DIR}/aidock.conf"
    fi

    info_default=$(timeout "${TIMEOUT}" "${LAUNCHER}" info 2>&1)
    if echo "$info_default" | grep -q "Commit policy: always"; then
        pass "default commit policy is 'always'"
    else
        fail "default commit policy is 'always'" "got: $info_default"
    fi

    # CLI override (--commit=prompt) wins over conf
    info_override=$(timeout "${TIMEOUT}" "${LAUNCHER}" run --dry-run --no-rebuild --agent copilot --commit=prompt 2>&1 || true)
    # info doesn't accept --commit, so use run --dry-run; we just need to verify
    # the parser accepts the flag without error
    if echo "$info_override" | grep -qE "(Would run|aidock-)"; then
        pass "--commit=prompt accepted on 'run' subcommand"
    else
        fail "--commit=prompt accepted on 'run' subcommand" "got: $info_override"
    fi

    # Conf-file override
    saved_conf=$(cat "${CONFIG_DIR}/aidock.conf")
    echo "commit_on_exit=never" >"${CONFIG_DIR}/aidock.conf"
    info_never=$(timeout "${TIMEOUT}" "${LAUNCHER}" info 2>&1)
    if echo "$info_never" | grep -q "Commit policy: never"; then
        pass "aidock.conf overrides default"
    else
        fail "aidock.conf overrides default" "got: $info_never"
    fi

    # CLI flag wins over conf
    info_cli_wins=$(timeout "${TIMEOUT}" "${LAUNCHER}" run --dry-run --no-rebuild --commit always 2>&1 || true)
    # We can't easily inspect dry-run policy; assert the flag is accepted (no error)
    if ! echo "$info_cli_wins" | grep -qi "error"; then
        pass "--commit always accepted (CLI overrides conf)"
    else
        fail "--commit always accepted (CLI overrides conf)" "got: $info_cli_wins"
    fi

    # Invalid value rejected
    bad_value=$(timeout "${TIMEOUT}" "${LAUNCHER}" run --dry-run --no-rebuild --commit=bogus 2>&1 || true)
    if echo "$bad_value" | grep -q "must be one of: always, prompt, never"; then
        pass "--commit rejects invalid value"
    else
        fail "--commit rejects invalid value" "got: $bad_value"
    fi

    # --commit not allowed on other subcommands
    bad_subcmd=$(timeout "${TIMEOUT}" "${LAUNCHER}" build --commit=always 2>&1 || true)
    if echo "$bad_subcmd" | grep -q "only valid with"; then
        pass "--commit rejected on non-run/shell subcommands"
    else
        fail "--commit rejected on non-run/shell subcommands" "got: $bad_subcmd"
    fi

    # Restore conf
    echo "$saved_conf" >"${CONFIG_DIR}/aidock.conf"

    # ── list-sessions ────────────────────────────────────────────────────

    section "list-sessions"

    # With no recorded sessions, command exits 0 with friendly message
    rm -rf "${TEST_SESSION_DIR:-$HOME/.local/share/aidock/sessions}" 2>/dev/null || true
    no_sess=$(timeout "${TIMEOUT}" "${LAUNCHER}" list-sessions 2>&1 || true)
    if echo "$no_sess" | grep -q "No recorded sessions"; then
        pass "list-sessions empty when nothing recorded"
    else
        fail "list-sessions empty when nothing recorded" "got: $no_sess"
    fi

    # Seed a fake session record and expect it to render with HASH/IMAGE/CWD
    sd="${XDG_DATA_HOME:-$HOME/.local/share}/aidock/sessions"
    mkdir -p "$sd"
    fake_hash="abcdef012345"
    echo "/tmp/some-fake-cwd" >"${sd}/${fake_hash}"
    listed=$(timeout "${TIMEOUT}" "${LAUNCHER}" list-sessions 2>&1 || true)
    if echo "$listed" | grep -q "$fake_hash" &&
        echo "$listed" | grep -q "/tmp/some-fake-cwd" &&
        echo "$listed" | grep -q "missing"; then
        pass "list-sessions renders recorded sessions"
    else
        fail "list-sessions renders recorded sessions" "got: $listed"
    fi
    rm -f "${sd}/${fake_hash}"

    # ── reset --session ──────────────────────────────────────────────────

    section "reset --session"

    rs_dry=$(timeout "${TIMEOUT}" "${LAUNCHER}" reset --session --dry-run 2>&1 || true)
    if echo "$rs_dry" | grep -q "Would run.*rmi.*${PROJECT_NAME}-session-" &&
        echo "$rs_dry" | grep -q "Would remove:.*sessions/[0-9a-f]\+"; then
        pass "reset --session dry-run shows actions"
    else
        fail "reset --session dry-run shows actions" "got: $rs_dry"
    fi

    rs_excl=$(timeout "${TIMEOUT}" "${LAUNCHER}" reset --session --purge 2>&1 || true)
    if echo "$rs_excl" | grep -q "mutually exclusive"; then
        pass "reset --session and --purge are mutually exclusive"
    else
        fail "reset --session and --purge are mutually exclusive" "got: $rs_excl"
    fi

    rs_outside=$(timeout "${TIMEOUT}" "${LAUNCHER}" run --session 2>&1 || true)
    if echo "$rs_outside" | grep -q "only valid with the 'reset'"; then
        pass "--session rejected outside reset"
    else
        fail "--session rejected outside reset" "got: $rs_outside"
    fi

    # ── update-agents ────────────────────────────────────────────────────

    section "update-agents"

    # No image present → dry-run reports the build-first hint.
    ua_no_image=$(timeout "${TIMEOUT}" "${LAUNCHER}" update-agents --dry-run 2>&1 || true)
    if echo "$ua_no_image" | grep -q "would fall through to 'aidock build'"; then
        pass "update-agents dry-run reports build-first when no image"
    else
        fail "update-agents dry-run reports build-first when no image" "got: $ua_no_image"
    fi

    # Fake a base image so dry-run shows the update plan.
    fake_base="${CONFIG_DIR}/.fake-image-${RANDOM}"
    mkdir -p "$fake_base"
    cat >"${fake_base}/engine" <<EOF
#!/usr/bin/env bash
case "\$1" in
    image) [[ "\$2" == "inspect" && "\$3" == "${PROJECT_NAME}-base" ]] && exit 0 || exit 1 ;;
esac
exit 1
EOF
    chmod +x "${fake_base}/engine"
    ua_dry=$(CONTAINER_ENGINE="${fake_base}/engine" PATH="${fake_base}:$PATH" \
        timeout "${TIMEOUT}" "${LAUNCHER}" update-agents --dry-run 2>&1 || true)
    if echo "$ua_dry" | grep -q "target image: ${PROJECT_NAME}-base" &&
        echo "$ua_dry" | grep -q "npm install -g @github/copilot @anthropic-ai/claude-code @openai/codex" &&
        echo "$ua_dry" | grep -q "Would run.*commit.*${PROJECT_NAME}-session-"; then
        pass "update-agents dry-run plan against base image"
    else
        fail "update-agents dry-run plan against base image" "got: $ua_dry"
    fi

    # Filter: only configured agents are reinstalled.
    ua_filtered=$(env -u ANTHROPIC_API_KEY -u OPENAI_API_KEY \
        HOME="${TEST_TMPDIR}" \
        CONTAINER_ENGINE="${fake_base}/engine" PATH="${fake_base}:$PATH" \
        timeout "${TIMEOUT}" "${LAUNCHER}" update-agents --dry-run 2>&1 || true)
    if echo "$ua_filtered" | grep -q "configured agents: copilot$" &&
        echo "$ua_filtered" | grep -q "npm install -g @github/copilot &&" &&
        ! echo "$ua_filtered" | grep -q "@anthropic-ai/claude-code" &&
        ! echo "$ua_filtered" | grep -q "@openai/codex"; then
        pass "update-agents reinstalls only configured agents"
    else
        fail "update-agents reinstalls only configured agents" "got: $ua_filtered"
    fi

    # No agents configured → dies with all hints.
    ua_zero=$(env -u GH_TOKEN -u ANTHROPIC_API_KEY -u OPENAI_API_KEY \
        HOME="${TEST_TMPDIR}" \
        CONTAINER_ENGINE="${fake_base}/engine" PATH="${fake_base}:$PATH" \
        timeout "${TIMEOUT}" "${LAUNCHER}" update-agents --dry-run 2>&1 || true)
    if echo "$ua_zero" | grep -q "no agent is configured"; then
        pass "update-agents dies when no agents configured"
    else
        fail "update-agents dies when no agents configured" "got: $ua_zero"
    fi

    rm -rf "$fake_base"

    # ── Host config bind-mount allowlist ─────────────────────────────────

    section "Host config bind-mount allowlist"

    fake_home="${TEST_TMPDIR}/fake-home-${RANDOM}"
    mkdir -p "${fake_home}/.config/github-copilot"
    mkdir -p "${fake_home}/.claude"
    mkdir -p "${fake_home}/.codex"
    # Copilot: create apps.json and hosts.json, but NOT versions.json.
    echo '{}' >"${fake_home}/.config/github-copilot/apps.json"
    echo '{}' >"${fake_home}/.config/github-copilot/hosts.json"
    echo '{}' >"${fake_home}/.claude/.credentials.json"
    echo '{}' >"${fake_home}/.codex/auth.json"

    cop_dry=$(HOME="$fake_home" timeout "${TIMEOUT}" "${LAUNCHER}" run --dry-run --agent copilot 2>&1 || true)
    if echo "$cop_dry" | grep -q "${fake_home}/.config/github-copilot/apps.json:${CONTAINER_HOME}/.config/github-copilot/apps.json:rw" &&
        echo "$cop_dry" | grep -q "${fake_home}/.config/github-copilot/hosts.json:${CONTAINER_HOME}/.config/github-copilot/hosts.json:rw" &&
        ! echo "$cop_dry" | grep -q "versions.json"; then
        pass "copilot mounts only allowlisted host config files that exist"
    else
        fail "copilot mounts only allowlisted host config files that exist" "got: $cop_dry"
    fi

    cla_dry=$(HOME="$fake_home" ANTHROPIC_API_KEY=fake timeout "${TIMEOUT}" "${LAUNCHER}" run --dry-run --agent claude 2>&1 || true)
    if echo "$cla_dry" | grep -q "${fake_home}/.claude/.credentials.json:${CONTAINER_HOME}/.claude/.credentials.json:rw"; then
        pass "claude mounts host credentials when present"
    else
        fail "claude mounts host credentials when present" "got: $cla_dry"
    fi

    cod_dry=$(HOME="$fake_home" OPENAI_API_KEY=fake timeout "${TIMEOUT}" "${LAUNCHER}" run --dry-run --agent codex 2>&1 || true)
    if echo "$cod_dry" | grep -q "${fake_home}/.codex/auth.json:${CONTAINER_HOME}/.codex/auth.json:rw"; then
        pass "codex mounts host auth.json when present"
    else
        fail "codex mounts host auth.json when present" "got: $cod_dry"
    fi

    empty_home="${TEST_TMPDIR}/empty-home-${RANDOM}"
    mkdir -p "$empty_home"
    none_dry=$(HOME="$empty_home" timeout "${TIMEOUT}" "${LAUNCHER}" run --dry-run --agent copilot 2>&1 || true)
    if ! echo "$none_dry" | grep -q "github-copilot.*:rw"; then
        pass "no host config mounts when files absent"
    else
        fail "no host config mounts when files absent" "got: $none_dry"
    fi
    rm -rf "$fake_home" "$empty_home"

    # ── First-run message ────────────────────────────────────────────────

    section "First-run message"

    # First-run message is tied to image build state, not per-agent dirs.
    # When the image is already built and no source files changed, the
    # first-run message must NOT appear.
    second_run_output=$(timeout "${TIMEOUT}" "${LAUNCHER}" run --dry-run --no-rebuild --agent codex 2>&1)
    if ! echo "$second_run_output" | grep -q "First run"; then
        pass "no first-run message when image is built"
    else
        fail "no first-run message when image is built" "got: $second_run_output"
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
    if [[ -f "${CONFIG_DIR}/Containerfile" ]] && [[ -f "${CONFIG_DIR}/init-home.sh" ]]; then
        pass "build files present after reset"
    else
        fail "build files present after reset" "Containerfile or init-home.sh missing"
    fi

    # --info should show Containerfile path
    info_output=$(timeout "${TIMEOUT}" "${LAUNCHER}" info 2>&1)
    if echo "$info_output" | grep -q "Containerfile:"; then
        pass "info shows Containerfile path"
    else
        fail "info shows Containerfile path" "got: $info_output"
    fi

    section "Installed artifact (standalone launcher smoke test)"

    # Copy launcher to isolated dir — no adjacent repo files
    smoke_dir=$(mktemp -d)
    smoke_cfg=$(mktemp -d)
    cp "${LAUNCHER}" "${smoke_dir}/aidock"
    chmod +x "${smoke_dir}/aidock"

    # Seeding works from inlined heredoc defaults
    smoke_dry=$(XDG_CONFIG_HOME="$smoke_cfg" GH_TOKEN=fake timeout "${TIMEOUT}" "${smoke_dir}/aidock" --dry-run 2>&1 || true)
    if [[ -f "${smoke_cfg}/aidock/Containerfile" ]]; then
        pass "standalone launcher seeds Containerfile from inlined heredocs"
    else
        fail "standalone launcher seeds Containerfile from inlined heredocs" "file not found after dry-run"
    fi

    rm -rf "$smoke_dir" "$smoke_cfg"

fi # end $RUN_UNIT

# ── Summary ──────────────────────────────────────────────────────────

printf "\n\033[1m── Test summary ──\033[0m\n"
printf "  \033[32m%d passed\033[0m" "$PASS"
[[ $FAIL -gt 0 ]] && printf "  \033[31m%d failed\033[0m" "$FAIL"
printf "\n"

exit "$FAIL"
