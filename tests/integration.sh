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

    fi # end CI skip (auto-rebuild)

    # ── Per-agent binary checks ──────────────────────────────────────────

    section "Per-agent binary checks"

    for test_agent in copilot claude codex; do
        mkdir -p "${CONFIG_DIR}/${test_agent}"
        agent_check=$(timeout "${TIMEOUT}" "$ENGINE" run --rm $(engine_userns_flags) \
            -v "${CONFIG_DIR}/${test_agent}:${CONTAINER_HOME}/.${test_agent}/:rw" \
            -v "${SCRIPT_DIR}:${SCRIPT_DIR}:rw" \
            -v "${PROJECT_NAME}-agents:/opt/aidock/agents:z" \
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

    # ── Per-agent auth warnings ──────────────────────────────────────────

    section "Per-agent auth (checkhealth)"

    # Claude without ANTHROPIC_API_KEY should warn, not fail
    claude_data_dir="${CONFIG_DIR}/claude"
    mkdir -p "${claude_data_dir}"
    claude_auth_output=$(timeout "${TIMEOUT}" "$ENGINE" run --rm $(engine_userns_flags) \
        -v "${claude_data_dir}:${CONTAINER_HOME}/.claude/:rw" \
        -v "${SCRIPT_DIR}:${SCRIPT_DIR}:rw" \
        -e "HOME=${CONTAINER_HOME}" \
        -e "AGENT=claude" \
        -e "AGENT_CONFIG_DIR=.claude" \
        -e "PROJECT_NAME=${PROJECT_NAME}" \
        -w "${SCRIPT_DIR}" \
        "${IMAGE_NAME}" \
        aidock __checkhealth 2>&1 || true)

    if echo "$claude_auth_output" | grep -q "ANTHROPIC_API_KEY not set"; then
        pass "claude auth warning shown when key missing"
    else
        fail "claude auth warning not shown" "expected ANTHROPIC_API_KEY warning"
    fi

    # Codex without OPENAI_API_KEY should warn, not fail
    codex_data_dir="${CONFIG_DIR}/codex"
    mkdir -p "${codex_data_dir}"
    codex_auth_output=$(timeout "${TIMEOUT}" "$ENGINE" run --rm $(engine_userns_flags) \
        -v "${codex_data_dir}:${CONTAINER_HOME}/.codex/:rw" \
        -v "${SCRIPT_DIR}:${SCRIPT_DIR}:rw" \
        -e "HOME=${CONTAINER_HOME}" \
        -e "AGENT=codex" \
        -e "AGENT_CONFIG_DIR=.codex" \
        -e "PROJECT_NAME=${PROJECT_NAME}" \
        -w "${SCRIPT_DIR}" \
        "${IMAGE_NAME}" \
        aidock __checkhealth 2>&1 || true)

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

    # --no-cache is now a general flag (no longer rejected outside any specific subcommand)
    nc_general=$(timeout "${TIMEOUT}" "${LAUNCHER}" --no-cache info 2>&1 || true)
    if ! echo "$nc_general" | grep -q "only valid with"; then
        pass "--no-cache accepted as general flag"
    else
        fail "--no-cache accepted as general flag" "got: $nc_general"
    fi

    # purge -a --force deletes agent dir entirely
    mkdir -p "${CONFIG_DIR}/codex"
    touch "${CONFIG_DIR}/codex/sentinel"
    reset_purge_output=$(timeout "${TIMEOUT}" "${LAUNCHER}" purge --force --agent codex 2>&1)
    if [[ ! -d "${CONFIG_DIR}/codex" ]] && echo "$reset_purge_output" | grep -q "Purged"; then
        pass "purge deletes agent dir"
    else
        fail "purge deletes agent dir" "dir still exists or wrong output: $reset_purge_output"
    fi

    # --force rejected outside purge
    _purge_out=$(timeout "${TIMEOUT}" "${LAUNCHER}" info --force 2>&1)
    _purge_rc=$?
    if echo "$_purge_out" | grep -q "error.*--force"; then
        pass "--force rejected outside purge"
    else
        fail "--force rejected outside purge" "rc=$_purge_rc out=[$_purge_out]"
    fi

    # ── Update / Clean modes ─────────────────────────────────────────────

    section "Update / Clean modes"

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
    if echo "$clean_dry" | grep -q "Would run: .* volume rm ${PROJECT_NAME}-agents"; then
        pass "clean --dry-run removes agents volume"
    else
        fail "clean --dry-run removes agents volume" "got: $clean_dry"
    fi

    # purge --dry-run removes the agents volume on global purge
    purge_dry=$(timeout "${TIMEOUT}" "${LAUNCHER}" purge --dry-run 2>&1)
    if echo "$purge_dry" | grep -q "Would run: .* volume rm ${PROJECT_NAME}-agents"; then
        pass "purge --dry-run removes agents volume"
    else
        fail "purge --dry-run removes agents volume" "got: $purge_dry"
    fi

    # purge --agent X --dry-run leaves the agents volume alone
    purge_agent_dry=$(timeout "${TIMEOUT}" "${LAUNCHER}" purge --dry-run --agent copilot 2>&1 || true)
    if ! echo "$purge_agent_dry" | grep -q "volume rm ${PROJECT_NAME}-agents"; then
        pass "purge --agent does not touch agents volume"
    else
        fail "purge --agent does not touch agents volume" "got: $purge_agent_dry"
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

    # Picker also runs in shell mode (consistent with run mode).
    shell_no_tty=$(timeout "${TIMEOUT}" "${LAUNCHER}" shell --dry-run --no-rebuild </dev/null 2>&1 || true)
    if echo "$shell_no_tty" | grep -q "multiple agents configured" &&
        echo "$shell_no_tty" | grep -q "no TTY"; then
        pass "picker dies on multi-configured + non-TTY in shell mode"
    else
        fail "picker dies on multi-configured + non-TTY in shell mode" "got: $shell_no_tty"
    fi

    # Explicit --agent skips the picker in shell mode too.
    shell_explicit=$(timeout "${TIMEOUT}" "${LAUNCHER}" shell --dry-run --no-rebuild --agent codex </dev/null 2>&1 || true)
    if echo "$shell_explicit" | grep -q "AGENT=codex" &&
        ! echo "$shell_explicit" | grep -q "multiple agents configured"; then
        pass "picker skipped in shell mode when --agent is explicit"
    else
        fail "picker skipped in shell mode when --agent is explicit" "got: $shell_explicit"
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
    bad_subcmd=$(timeout "${TIMEOUT}" "${LAUNCHER}" info --commit=always 2>&1 || true)
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
        echo "$listed" | grep -q "missing" &&
        echo "$listed" | grep -q "SIZE"; then
        pass "list-sessions renders recorded sessions"
    else
        fail "list-sessions renders recorded sessions" "got: $listed"
    fi
    rm -f "${sd}/${fake_hash}"

    # ── prune ───────────────────────────────────────────────────────────

    section "prune"

    # Seed a fake orphan record (CWD does not exist) and a live one
    rm -rf "$sd" 2>/dev/null || true
    mkdir -p "$sd"
    orphan_hash="aaaaaaaaaaaa"
    live_hash="bbbbbbbbbbbb"
    live_cwd=$(mktemp -d)
    echo "/tmp/this-cwd-does-not-exist-xyz" >"${sd}/${orphan_hash}"
    echo "$live_cwd" >"${sd}/${live_hash}"

    # bare prune is a dry-run listing
    p_out=$(timeout "${TIMEOUT}" "${LAUNCHER}" prune 2>&1 || true)
    if echo "$p_out" | grep -q "$orphan_hash" &&
        ! echo "$p_out" | grep -q "$live_hash" &&
        echo "$p_out" | grep -q "prune --orphans"; then
        pass "prune lists orphans without removing"
    else
        fail "prune lists orphans without removing" "got: $p_out"
    fi

    # Records still on disk after dry-run
    if [[ -f "${sd}/${orphan_hash}" && -f "${sd}/${live_hash}" ]]; then
        pass "prune dry-run preserves records"
    else
        fail "prune dry-run preserves records" "files missing"
    fi

    # prune --orphans actually removes
    timeout "${TIMEOUT}" "${LAUNCHER}" prune --orphans >/dev/null 2>&1 || true
    if [[ ! -f "${sd}/${orphan_hash}" && -f "${sd}/${live_hash}" ]]; then
        pass "prune --orphans removes orphan records only"
    else
        fail "prune --orphans removes orphan records only" "orphan still=$(ls "${sd}")"
    fi

    # --orphans rejected outside prune
    o_outside=$(timeout "${TIMEOUT}" "${LAUNCHER}" info --orphans 2>&1 || true)
    if echo "$o_outside" | grep -qi "only valid with the 'prune'"; then
        pass "--orphans rejected outside prune"
    else
        fail "--orphans rejected outside prune" "got: $o_outside"
    fi

    # No orphans → friendly message
    no_orph=$(timeout "${TIMEOUT}" "${LAUNCHER}" prune 2>&1 || true)
    if echo "$no_orph" | grep -q "No orphan sessions found"; then
        pass "prune prints friendly message when no orphans"
    else
        fail "prune prints friendly message when no orphans" "got: $no_orph"
    fi

    rm -rf "$live_cwd"
    rm -f "${sd}/${live_hash}"

    # ── drop-session ────────────────────────────────────────────────────

    section "drop-session"

    rs_dry=$(timeout "${TIMEOUT}" "${LAUNCHER}" drop-session --dry-run 2>&1 || true)
    if echo "$rs_dry" | grep -q "Would run.*rmi.*${PROJECT_NAME}-session-" &&
        echo "$rs_dry" | grep -q "Would remove:.*sessions/[0-9a-f]\+"; then
        pass "drop-session dry-run shows actions"
    else
        fail "drop-session dry-run shows actions" "got: $rs_dry"
    fi

    # ── update-agents ────────────────────────────────────────────────────

    section "update-agents"

    # No image present → dry-run reports the build-first hint.
    # Use a fake engine that always reports no image so this works even when
    # the real engine has the base image cached from earlier tests.
    fake_no_image="${CONFIG_DIR}/.fake-no-image-${RANDOM}"
    mkdir -p "$fake_no_image"
    cat >"${fake_no_image}/engine" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${fake_no_image}/engine"
    ua_no_image=$(CONTAINER_ENGINE="${fake_no_image}/engine" PATH="${fake_no_image}:$PATH" \
        timeout "${TIMEOUT}" "${LAUNCHER}" update-agents --dry-run 2>&1 || true)
    if echo "$ua_no_image" | grep -q "would build first" && echo "$ua_no_image" | grep -q "Would run: .* build .*${PROJECT_NAME}-base"; then
        pass "update-agents dry-run reports build-first when no image"
    else
        fail "update-agents dry-run reports build-first when no image" "got: $ua_no_image"
    fi
    rm -rf "$fake_no_image"

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
    if echo "$ua_dry" | grep -q "configured agents: copilot claude codex" &&
        echo "$ua_dry" | grep -q "Would update ${PROJECT_NAME}-agents: npm install -g @github/copilot @anthropic-ai/claude-code @openai/codex"; then
        pass "update-agents dry-run plan against shared volume"
    else
        fail "update-agents dry-run plan against shared volume" "got: $ua_dry"
    fi

    # Filter: only configured agents are reinstalled.
    ua_filtered=$(env -u ANTHROPIC_API_KEY -u OPENAI_API_KEY \
        HOME="${TEST_TMPDIR}" \
        CONTAINER_ENGINE="${fake_base}/engine" PATH="${fake_base}:$PATH" \
        timeout "${TIMEOUT}" "${LAUNCHER}" update-agents --dry-run 2>&1 || true)
    if echo "$ua_filtered" | grep -q "configured agents: copilot$" &&
        echo "$ua_filtered" | grep -q "Would update ${PROJECT_NAME}-agents: npm install -g @github/copilot$" &&
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

    # ── Shared agents volume ─────────────────────────────────────────────

    section "shared agents volume"

    # Containerfile no longer bakes agent CLIs into the image; they live
    # in /opt/aidock/agents (the shared volume).
    cf_emit=$("${LAUNCHER}" --emit-default Containerfile 2>/dev/null || true)
    if echo "$cf_emit" | grep -q 'NPM_CONFIG_PREFIX="/opt/aidock/agents"'; then
        pass "Containerfile sets NPM_CONFIG_PREFIX to shared volume"
    else
        fail "Containerfile sets NPM_CONFIG_PREFIX to shared volume" "got: $cf_emit"
    fi

    if echo "$cf_emit" | grep -q 'PATH="/opt/aidock/agents/bin:'; then
        pass "Containerfile prepends /opt/aidock/agents/bin to PATH"
    else
        fail "Containerfile prepends /opt/aidock/agents/bin to PATH" "got: $cf_emit"
    fi

    if echo "$cf_emit" | grep -qE 'npm install -g.*@github/copilot'; then
        fail "Containerfile no longer pre-installs agent CLIs" "@github/copilot still present in npm install"
    else
        pass "Containerfile no longer pre-installs agent CLIs"
    fi

    # build dry-run mentions the seed step (and includes the volume name).
    fake_seed_dry="${CONFIG_DIR}/.fake-seed-${RANDOM}"
    mkdir -p "$fake_seed_dry"
    cat >"${fake_seed_dry}/engine" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "${fake_seed_dry}/engine"
    build_dry=$(CONTAINER_ENGINE="${fake_seed_dry}/engine" PATH="${fake_seed_dry}:$PATH" \
        timeout "${TIMEOUT}" "${LAUNCHER}" update --dry-run 2>&1 || true)
    if echo "$build_dry" | grep -q "Would seed ${PROJECT_NAME}-agents: npm install -g @github/copilot"; then
        pass "update --dry-run announces agents-volume seed step"
    else
        fail "update --dry-run announces agents-volume seed step" "got: $build_dry"
    fi

    # When zero agents are configured, build dry-run skips the seed.
    build_dry_zero=$(env -u GH_TOKEN -u ANTHROPIC_API_KEY -u OPENAI_API_KEY \
        HOME="${TEST_TMPDIR}" \
        CONTAINER_ENGINE="${fake_seed_dry}/engine" PATH="${fake_seed_dry}:$PATH" \
        timeout "${TIMEOUT}" "${LAUNCHER}" update --dry-run 2>&1 || true)
    if echo "$build_dry_zero" | grep -q "would skip agents-volume seed (no configured agents)"; then
        pass "update --dry-run skips seed when no agents configured"
    else
        fail "update --dry-run skips seed when no agents configured" "got: $build_dry_zero"
    fi

    # Seed filter: only configured agents are seeded.
    build_dry_filter=$(env -u ANTHROPIC_API_KEY -u OPENAI_API_KEY \
        HOME="${TEST_TMPDIR}" \
        CONTAINER_ENGINE="${fake_seed_dry}/engine" PATH="${fake_seed_dry}:$PATH" \
        timeout "${TIMEOUT}" "${LAUNCHER}" update --dry-run 2>&1 || true)
    if echo "$build_dry_filter" | grep -q "Would seed ${PROJECT_NAME}-agents: npm install -g @github/copilot$" &&
        ! echo "$build_dry_filter" | grep -q "@anthropic-ai/claude-code" &&
        ! echo "$build_dry_filter" | grep -q "@openai/codex"; then
        pass "update seed step filters to configured agents"
    else
        fail "update seed step filters to configured agents" "got: $build_dry_filter"
    fi
    rm -rf "$fake_seed_dry"

    # ── Host config bind-mount allowlist ─────────────────────────────────

    section "Host config bind-mount allowlist"

    fake_home="${TEST_TMPDIR}/fake-home-${RANDOM}"
    mkdir -p "${fake_home}/.config/github-copilot/skills"
    mkdir -p "${fake_home}/.claude"
    mkdir -p "${fake_home}/.codex"
    # Copilot: create apps.json, hosts.json, settings.json (but NOT versions.json).
    echo '{}' >"${fake_home}/.config/github-copilot/apps.json"
    echo '{}' >"${fake_home}/.config/github-copilot/hosts.json"
    echo '{}' >"${fake_home}/.config/github-copilot/settings.json"
    echo '{}' >"${fake_home}/.claude/.credentials.json"
    echo '{}' >"${fake_home}/.claude/settings.json"
    echo '# rules' >"${fake_home}/.claude/CLAUDE.md"
    echo '{}' >"${fake_home}/.codex/auth.json"
    echo '' >"${fake_home}/.codex/config.toml"
    echo '# rules' >"${fake_home}/.codex/AGENTS.md"

    cop_dry=$(HOME="$fake_home" timeout "${TIMEOUT}" "${LAUNCHER}" run --dry-run --agent copilot 2>&1 || true)
    if echo "$cop_dry" | grep -q "${fake_home}/.config/github-copilot/apps.json:${CONTAINER_HOME}/.config/github-copilot/apps.json:rw" &&
        echo "$cop_dry" | grep -q "${fake_home}/.config/github-copilot/hosts.json:${CONTAINER_HOME}/.config/github-copilot/hosts.json:rw" &&
        echo "$cop_dry" | grep -q "${fake_home}/.config/github-copilot/settings.json:${CONTAINER_HOME}/.config/github-copilot/settings.json:rw" &&
        echo "$cop_dry" | grep -q "${fake_home}/.config/github-copilot/skills:${CONTAINER_HOME}/.config/github-copilot/skills:rw" &&
        ! echo "$cop_dry" | grep -q "versions.json"; then
        pass "copilot mounts only allowlisted host config files that exist"
    else
        fail "copilot mounts only allowlisted host config files that exist" "got: $cop_dry"
    fi

    cla_dry=$(HOME="$fake_home" ANTHROPIC_API_KEY=fake timeout "${TIMEOUT}" "${LAUNCHER}" run --dry-run --agent claude 2>&1 || true)
    if echo "$cla_dry" | grep -q "${fake_home}/.claude/.credentials.json:${CONTAINER_HOME}/.claude/.credentials.json:rw" &&
        echo "$cla_dry" | grep -q "${fake_home}/.claude/settings.json:${CONTAINER_HOME}/.claude/settings.json:rw" &&
        echo "$cla_dry" | grep -q "${fake_home}/.claude/CLAUDE.md:${CONTAINER_HOME}/.claude/CLAUDE.md:rw"; then
        pass "claude mounts credentials, settings, and CLAUDE.md when present"
    else
        fail "claude mounts credentials, settings, and CLAUDE.md when present" "got: $cla_dry"
    fi

    cod_dry=$(HOME="$fake_home" OPENAI_API_KEY=fake timeout "${TIMEOUT}" "${LAUNCHER}" run --dry-run --agent codex 2>&1 || true)
    if echo "$cod_dry" | grep -q "${fake_home}/.codex/auth.json:${CONTAINER_HOME}/.codex/auth.json:rw" &&
        echo "$cod_dry" | grep -q "${fake_home}/.codex/config.toml:${CONTAINER_HOME}/.codex/config.toml:rw" &&
        echo "$cod_dry" | grep -q "${fake_home}/.codex/AGENTS.md:${CONTAINER_HOME}/.codex/AGENTS.md:rw"; then
        pass "codex mounts auth.json, config.toml, and AGENTS.md when present"
    else
        fail "codex mounts auth.json, config.toml, and AGENTS.md when present" "got: $cod_dry"
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

    # The launcher itself should be copied into BUILD_DIR (entrypoint host)
    if [[ -f "${CONFIG_DIR}/aidock" ]] && [[ -x "${CONFIG_DIR}/aidock" ]]; then
        pass "launcher copied into build dir"
    else
        fail "launcher copied into build dir" "aidock missing or not executable in ${CONFIG_DIR}"
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

    # reset-build should overwrite build files with defaults
    echo "# user customization for reset test" >>"${CONFIG_DIR}/Containerfile"
    timeout "${TIMEOUT}" "${LAUNCHER}" reset-build >/dev/null 2>&1
    if [[ -f "${CONFIG_DIR}/Containerfile" ]] && ! grep -q "# user customization for reset test" "${CONFIG_DIR}/Containerfile"; then
        pass "reset-build overwrites build files with defaults"
    else
        fail "reset-build overwrites build files with defaults" "customization still present or Containerfile missing"
    fi

    # .last-build should be removed (triggers rebuild)
    if [[ ! -f "${CONFIG_DIR}/.last-build" ]]; then
        pass "reset-build removes .last-build marker"
    else
        fail "reset-build removes .last-build marker"
    fi

    # Build files should still exist (overwritten, not deleted)
    if [[ -f "${CONFIG_DIR}/Containerfile" ]] && [[ -f "${CONFIG_DIR}/aidock" ]]; then
        pass "build files present after reset-build"
    else
        fail "build files present after reset-build" "Containerfile or aidock missing"
    fi

    # reset-build rejects --agent
    rb_agent=$(timeout "${TIMEOUT}" "${LAUNCHER}" reset-build --agent codex 2>&1 || true)
    if echo "$rb_agent" | grep -q "does not accept --agent"; then
        pass "reset-build rejects --agent"
    else
        fail "reset-build rejects --agent" "got: $rb_agent"
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

    # ── Hidden subcommand guards ──────────────────────────────────────
    section "Hidden subcommand guards"

    # __checkhealth on the host (no AGENT env) should fail predictably,
    # not silently succeed. This protects the in-container assumption.
    hh_out=$(
        unset AGENT
        "${LAUNCHER}" __checkhealth 2>&1 || true
    )
    if echo "$hh_out" | grep -qi "AGENT"; then
        pass "__checkhealth requires AGENT env var"
    else
        fail "__checkhealth requires AGENT env var" "got: $hh_out"
    fi

    # __init-home on the host (no required env) should fail, not exec
    # an arbitrary command in the user's shell.
    ih_out=$(
        unset PROJECT_NAME CONTAINER_HOME 2>/dev/null
        "${LAUNCHER}" __init-home /bin/true 2>&1 || true
    )
    if [[ -n "$ih_out" ]] && ! echo "$ih_out" | grep -q "would have exec"; then
        pass "__init-home guards required env vars"
    else
        fail "__init-home guards required env vars" "got: $ih_out"
    fi

    # ── Host config bind-mount checkhealth section ────────────────────
    section "Host config bind-mount checkhealth section"

    hcfg_tmp=$(mktemp -d)
    mkdir -p "${hcfg_tmp}/.config/github-copilot"
    touch "${hcfg_tmp}/.config/github-copilot/apps.json"
    hcfg_ok=$(
        AGENT=copilot AGENT_CONFIG_DIR=.config/github-copilot \
            PROJECT_NAME="${PROJECT_NAME}" HOME="${hcfg_tmp}" \
            "${LAUNCHER}" __checkhealth 2>&1 || true
    )
    if echo "$hcfg_ok" | grep -q "Host config bind mounts" &&
        echo "$hcfg_ok" | grep -q "apps.json (mounted)"; then
        pass "checkhealth pass when credential file present"
    else
        fail "checkhealth pass when credential file present" "got: $hcfg_ok"
    fi
    rm -rf "${hcfg_tmp}"

    hcfg_tmp=$(mktemp -d)
    hcfg_miss=$(
        AGENT=claude AGENT_CONFIG_DIR=.claude \
            PROJECT_NAME="${PROJECT_NAME}" HOME="${hcfg_tmp}" \
            "${LAUNCHER}" __checkhealth 2>&1 || true
    )
    if echo "$hcfg_miss" | grep -q ".credentials.json not mounted (auth will fail"; then
        pass "checkhealth fails when credential file missing"
    else
        fail "checkhealth fails when credential file missing" "got: $hcfg_miss"
    fi
    if echo "$hcfg_miss" | grep -q "settings.json not mounted (optional"; then
        pass "checkhealth warns on missing optional file"
    else
        fail "checkhealth warns on missing optional file" "got: $hcfg_miss"
    fi
    rm -rf "${hcfg_tmp}"

    # ── container.conf ────────────────────────────────────────────────
    section "container.conf extra args"

    # When container.conf has args, info subcommand stays quiet (no notice
    # in info/check), but a normal --dry-run run prints the [info] notice.
    mkdir -p "${CONFIG_DIR}"
    cat >"${CONFIG_DIR}/container.conf" <<'EOF'
--publish=3000:3000
# comment line
--env=FOO=bar
EOF
    cc_out=$(timeout "${TIMEOUT}" "${LAUNCHER}" --dry-run --agent copilot 2>&1 || true)
    if echo "$cc_out" | grep -q "applied 2 extra container args from"; then
        pass "container.conf prints [info] applied N notice"
    else
        fail "container.conf prints [info] applied N notice" "got: $cc_out"
    fi

    cc_info=$(timeout "${TIMEOUT}" "${LAUNCHER}" info 2>&1 || true)
    if ! echo "$cc_info" | grep -q "applied .* extra container args"; then
        pass "container.conf notice suppressed in info mode"
    else
        fail "container.conf notice suppressed in info mode" "got: $cc_info"
    fi
    rm -f "${CONFIG_DIR}/container.conf"

fi # end $RUN_UNIT

# ── Summary ──────────────────────────────────────────────────────────

printf "\n\033[1m── Test summary ──\033[0m\n"
printf "  \033[32m%d passed\033[0m" "$PASS"
[[ $FAIL -gt 0 ]] && printf "  \033[31m%d failed\033[0m" "$FAIL"
printf "\n"

exit "$FAIL"
