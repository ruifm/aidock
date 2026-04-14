#!/usr/bin/env bash
# build-dist.sh: Generate the distributable aidock script with embedded default assets.
# Reads src/aidock, replaces the get_defaults_dir() function with self-extraction logic,
# and appends a base64-encoded tarball of defaults/.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${REPO_ROOT}/src/aidock"
OUT="${REPO_ROOT}/aidock"

if [[ ! -f "$SRC" ]]; then
    echo "error: source not found at ${SRC}" >&2
    exit 1
fi

# ── Build the embedded defaults payload ──────────────────────────────
payload=$(cd "$REPO_ROOT" && tar czf - -C defaults . | base64)

# ── Assemble the output ──────────────────────────────────────────────
{
    # Warning header
    cat <<'HEADER'
#!/usr/bin/env bash
# !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
# !! GENERATED FILE — DO NOT EDIT                                   !!
# !! Edit src/aidock instead, then run: just dist                   !!
# !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
HEADER

    # Source script with shebang/dev-header removed and defaults function replaced
    tail -n +2 "$SRC" |
        sed '/^# DEV SOURCE/d' |
        awk '
            /^# __DEFAULTS_BEGIN__/ {
                print "# Dist mode: defaults are embedded in this script as a base64 tarball."
                print "_DEFAULTS_DIR=\"\""
                print "_DEFAULTS_CLEANUP_DIR=\"\""
                print "get_defaults_dir() {"
                print "    if [[ -n \"$_DEFAULTS_DIR\" ]]; then return 0; fi"
                print "    local tmpdir"
                print "    tmpdir=$(mktemp -d)"
                print "    _DEFAULTS_CLEANUP_DIR=\"$tmpdir\""
                print "    sed -n '"'"'/^__DEFAULTS__$/,$ p'"'"' \"$0\" | tail -n +2 | base64 -d | tar xzf - -C \"$tmpdir\""
                print "    _DEFAULTS_DIR=\"$tmpdir\""
                print "}"
                print "cleanup_defaults_dir() { [[ -n \"${_DEFAULTS_CLEANUP_DIR:-}\" ]] && rm -rf \"$_DEFAULTS_CLEANUP_DIR\"; }"
                print "trap cleanup_defaults_dir EXIT"
                skip = 1
                next
            }
            /^# __DEFAULTS_END__$/ { skip = 0; next }
            !skip { print }
        '

    # Defaults payload
    echo ""
    echo "__DEFAULTS__"
    echo "$payload"
} >"$OUT"

chmod +x "$OUT"
echo "Generated: ${OUT} ($(wc -l <"$OUT") lines, $(wc -c <"$OUT" | tr -d ' ') bytes)"
