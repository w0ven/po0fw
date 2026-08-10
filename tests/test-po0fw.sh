#!/bin/sh
set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/po0fw-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT HUP INT TERM

mkdir -p "$TEST_TMP/bin"
cat > "$TEST_TMP/bin/curl" <<'EOF'
#!/bin/sh
printf '%s\n' '{"currentIp":"203.0.113.0\\/24","limit":5,"whitelist":[{"ip":"203.0.113.0\\/24","slot":0}]}'
EOF
chmod +x "$TEST_TMP/bin/curl"

run_po0fw() {
  PATH="$TEST_TMP/bin:$PATH" \
    PO0FW_CONF="$TEST_TMP/missing.conf" \
    /bin/sh "$ROOT/po0fw.sh" "$@"
}

add_output=$(run_po0fw 'pgnfw_ci_dummy@0')
printf '%s\n' "$add_output"
printf '%s\n' "$add_output" | grep -F '✅ 出口 203.0.113.0/24 已在白名单 (槽位 0)' >/dev/null

status_output=$(run_po0fw status 'pgnfw_ci_dummy@0')
printf '%s\n' "$status_output"
printf '%s\n' "$status_output" | grep -F '当前出口 203.0.113.0/24' >/dev/null
printf '%s\n' "$status_output" | grep -F '固定槽位 0，不淘汰' >/dev/null
printf '%s\n' "$status_output" | grep -F '✅ 当前出口已在白名单' >/dev/null

echo 'po0fw shell tests passed'
