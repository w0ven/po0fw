#!/bin/sh
set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/po0fw-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT HUP INT TERM

mkdir -p "$TEST_TMP/bin" "$TEST_TMP/state"

# 可编程 mock curl：记录每次调用的方法与 URL，并按场景返回预设状态码和响应体
cat > "$TEST_TMP/bin/curl" <<'EOF'
#!/bin/sh
STATE_DIR="${PO0FW_TEST_STATE:?}"
COUNT_FILE="$STATE_DIR/count"
LOG_FILE="$STATE_DIR/requests.log"

n=0
[ -f "$COUNT_FILE" ] && n=$(cat "$COUNT_FILE")
n=$((n + 1))
printf '%s\n' "$n" > "$COUNT_FILE"

method="GET"
url=""
write_out=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-X" ]; then
    method="$arg"
    prev=""
    continue
  fi
  if [ "$prev" = "-w" ]; then
    write_out="$arg"
    prev=""
    continue
  fi
  case "$arg" in
    -X|-w|-m|-o) prev="$arg"; continue ;;
    -*) continue ;;
    http://*|https://*) url="$arg" ;;
  esac
done

printf '%s %s\n' "$method" "$url" >> "$LOG_FILE"

mode="${PO0FW_TEST_SCENARIO:-normal}"
code="200"
body='{"enabled":true,"currentIp":"203.0.113.0\/24","limit":5,"whitelist":[{"ip":"203.0.113.0\/24","slot":0}]}'

case "$mode" in
  normal)
    ;;
  reversed_unescaped)
    # 字段逆序 + 含换行转义额外字段 + 未转义 / + 精确 currentIp 匹配 /24
    body='{"enabled":true,"note":"line1\nline2","currentIp":"203.0.113.42","limit":5,"whitelist":[{"slot":2,"extra":"ok","ip":"203.0.113.0/24"},{"slot":null,"ip":"198.51.100.0/24"}]}'
    ;;
  transient_400_then_ok)
    if [ "$n" -eq 1 ]; then
      code="400"
      body="Error"
    fi
    ;;
  conflict_403)
    code="403"
    body='{"code":403,"message":"slot conflict","currentIp":"203.0.113.0/24"}'
    ;;
  json_400)
    code="400"
    body='{"code":400,"message":"serviceId is required"}'
    ;;
  disabled)
    code="200"
    body='{"enabled":false,"currentIp":"203.0.113.0/24","limit":5,"whitelist":[]}'
    ;;
esac

printf '%s' "$body"
if [ -n "$write_out" ]; then
  printf '\n__HTTP_STATUS__:%s' "$code"
fi
EOF
chmod +x "$TEST_TMP/bin/curl"

# 加速重试测试中的 sleep
cat > "$TEST_TMP/bin/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$TEST_TMP/bin/sleep"

reset_state() {
  rm -f "$TEST_TMP/state/count" "$TEST_TMP/state/requests.log"
}

run_po0fw() {
  TMPDIR="$TEST_TMP" \
    PATH="$TEST_TMP/bin:$PATH" \
    PO0FW_TEST_STATE="$TEST_TMP/state" \
    PO0FW_CONF="${PO0FW_CONF_OVERRIDE:-$TEST_TMP/missing.conf}" \
    /bin/sh "$ROOT/po0fw.sh" "$@"
}

# 1. 标准 add 与只读 status 测试
reset_state
add_output=$(run_po0fw 'pgnfw_ci_dummy@0')
printf '%s\n' "$add_output" | grep -F '✅ 出口 203.0.113.0/24 已在白名单 (槽位 0)' >/dev/null
grep -F 'POST https://124.221.69.228/api/firewall/pgnfw_ci_dummy/add?slot=0' "$TEST_TMP/state/requests.log" >/dev/null

reset_state
status_output=$(run_po0fw status 'pgnfw_ci_dummy@0')
printf '%s\n' "$status_output" | grep -F '当前出口 203.0.113.0/24' >/dev/null
printf '%s\n' "$status_output" | grep -F '固定槽位 0，不淘汰' >/dev/null
printf '%s\n' "$status_output" | grep -F '✅ 当前出口已在白名单' >/dev/null
grep -F 'GET https://124.221.69.228/api/firewall/pgnfw_ci_dummy' "$TEST_TMP/state/requests.log" >/dev/null
if grep -F '/add' "$TEST_TMP/state/requests.log" >/dev/null 2>&1; then
  echo "FAIL: status mode must never call /add" >&2
  exit 1
fi

# 2. JSON 字段逆序、未转义斜杠、\n 转义串与精确 IP 匹配 /24
reset_state
rev_output=$(PO0FW_TEST_SCENARIO=reversed_unescaped run_po0fw 'pgnfw_rev@2')
printf '%s\n' "$rev_output" | grep -F '✅ 出口 203.0.113.42 已在白名单 (槽位 2)' >/dev/null
rev_status=$(PO0FW_TEST_SCENARIO=reversed_unescaped run_po0fw status 'pgnfw_rev')
printf '%s\n' "$rev_status" | grep -F -- '-> 203.0.113.0/24  (固定槽位 2，不淘汰)' >/dev/null
printf '%s\n' "$rev_status" | grep -F '198.51.100.0/24  (普通，参与 FIFO 淘汰)' >/dev/null

# 3. 瞬时裸 400 "Error" 自动重试自愈
reset_state
retry_output=$(PO0FW_TEST_SCENARIO=transient_400_then_ok run_po0fw 'pgnfw_retry')
printf '%s\n' "$retry_output" | grep -F '✅ 出口 203.0.113.0/24 已在白名单' >/dev/null
[ "$(cat "$TEST_TMP/state/count")" = "2" ]

# 4. 403 槽位冲突与规范 400 JSON 确定性错误不重试
reset_state
if conflict_out=$(PO0FW_TEST_SCENARIO=conflict_403 run_po0fw 'pgnfw_conflict@1' 2>&1); then
  echo "FAIL: 403 conflict must exit non-zero" >&2
  exit 1
fi
printf '%s\n' "$conflict_out" | grep -F '槽位冲突' >/dev/null
[ "$(cat "$TEST_TMP/state/count")" = "1" ]

reset_state
if err400_out=$(PO0FW_TEST_SCENARIO=json_400 run_po0fw 'pgnfw_bad' 2>&1); then
  echo "FAIL: 400 JSON error must exit non-zero" >&2
  exit 1
fi
printf '%s\n' "$err400_out" | grep -F 'HTTP 400' >/dev/null
printf '%s\n' "$err400_out" | grep -F 'serviceId is required' >/dev/null
[ "$(cat "$TEST_TMP/state/count")" = "1" ]

# 5. 防火墙未启用 (enabled: false) 必须告警且非 0 退出
reset_state
if dis_out=$(PO0FW_TEST_SCENARIO=disabled run_po0fw 'pgnfw_disabled' 2>&1); then
  echo "FAIL: disabled firewall must exit non-zero" >&2
  exit 1
fi
printf '%s\n' "$dis_out" | grep -F '防火墙未启用' >/dev/null

# 6. CLI 帮助、未知选项与非法槽位拦截（零网络请求）
reset_state
help_out=$(run_po0fw --help)
printf '%s\n' "$help_out" | grep -F '用法:' >/dev/null
[ ! -f "$TEST_TMP/state/requests.log" ]

if run_po0fw --unknown-flag >/dev/null 2>&1; then
  echo "FAIL: unknown option must fail" >&2
  exit 1
fi
[ ! -f "$TEST_TMP/state/requests.log" ]

if bad_slot_out=$(run_po0fw 'pgnfw_abc@ bad' 2>&1); then
  echo "FAIL: invalid slot must fail" >&2
  exit 1
fi
printf '%s\n' "$bad_slot_out" | grep -F '槽位号不能为空' >/dev/null
[ ! -f "$TEST_TMP/state/requests.log" ]

# 7. 配置文件安全解析（绝不执行潜在注入命令，兼容键值与裸 token）
PWN_FILE="$TEST_TMP/pwned"
SAFE_CONF="$TEST_TMP/safe.conf"
cat > "$SAFE_CONF" <<EOF
# comment
\$(touch "$PWN_FILE")
PO0FW_TOKENS="pgnfw_one@0 | pgnfw_two"
EOF
reset_state
conf_out=$(PO0FW_CONF_OVERRIDE="$SAFE_CONF" run_po0fw)
[ ! -e "$PWN_FILE" ]
printf '%s\n' "$conf_out" | grep -F '#1 pgnfw_one… ✅' >/dev/null
printf '%s\n' "$conf_out" | grep -F '#2 pgnfw_two… ✅' >/dev/null

# 8. 非 root 用户运行 install-linux.sh + po0fw uninstall 端到端验证
FAKE_HOME="$TEST_TMP/nonroot-home"
mkdir -p "$FAKE_HOME" "$TEST_TMP/nonroot-bin" "$TEST_TMP/stale-cwd"
cat > "$TEST_TMP/nonroot-bin/id" <<'EOF'
#!/bin/sh
printf '1000\n'
EOF
cat > "$TEST_TMP/nonroot-bin/crontab" <<EOF
#!/bin/sh
if [ "\${1:-}" = "-l" ]; then
  cat "$TEST_TMP/crontab.txt" 2>/dev/null || exit 1
elif [ "\${1:-}" = "-" ]; then
  cat > "$TEST_TMP/crontab.txt"
fi
EOF
cp "$TEST_TMP/bin/curl" "$TEST_TMP/nonroot-bin/curl"
chmod +x "$TEST_TMP/nonroot-bin/id" "$TEST_TMP/nonroot-bin/crontab" "$TEST_TMP/nonroot-bin/curl"

reset_state
HOME="$FAKE_HOME" \
  XDG_CONFIG_HOME="" \
  XDG_BIN_HOME="" \
  TERMUX_VERSION="" \
  TMPDIR="$TEST_TMP" \
  PATH="$TEST_TMP/nonroot-bin:$PATH" \
  PO0FW_TEST_STATE="$TEST_TMP/state" \
  PO0FW_TOKENS="pgnfw_macos_user@00" \
  /bin/sh "$ROOT/install-linux.sh" >/dev/null

[ -x "$FAKE_HOME/.local/bin/po0fw" ]
[ -f "$FAKE_HOME/.config/po0fw/po0fw.conf" ]
grep -F 'PO0FW_TOKENS="pgnfw_macos_user@00"' "$FAKE_HOME/.config/po0fw/po0fw.conf" >/dev/null
grep -F "$FAKE_HOME/.local/bin/po0fw" "$TEST_TMP/crontab.txt" >/dev/null
# 验证 @00 前导零已规范化为 ?slot=0
grep -F 'POST https://124.221.69.228/api/firewall/pgnfw_macos_user/add?slot=0' "$TEST_TMP/state/requests.log" >/dev/null

# 验证 po0fw uninstall 能干净移除配置、crontab 条目与已安装副本，同时保留源码仓库内的 po0fw.sh
HOME="$FAKE_HOME" \
  XDG_CONFIG_HOME="" \
  XDG_BIN_HOME="" \
  TERMUX_VERSION="" \
  PATH="$TEST_TMP/nonroot-bin:$PATH" \
  /bin/sh "$FAKE_HOME/.local/bin/po0fw" uninstall >/dev/null

[ ! -e "$FAKE_HOME/.local/bin/po0fw" ]
[ ! -e "$FAKE_HOME/.config/po0fw/po0fw.conf" ]
[ -f "$ROOT/po0fw.sh" ]
if grep -q 'po0fw' "$TEST_TMP/crontab.txt" 2>/dev/null; then
  echo "FAIL: crontab entry should be removed after uninstall" >&2
  exit 1
fi

# 9. 验证 `curl ... | sh` 管道模式下不会误拷当前工作目录中的同名旧 po0fw.sh
cat > "$TEST_TMP/stale-cwd/po0fw.sh" <<'EOF'
#!/bin/sh
echo "STALE_POISON_SCRIPT" >&2
exit 99
EOF
chmod +x "$TEST_TMP/stale-cwd/po0fw.sh"
cat > "$TEST_TMP/nonroot-bin/curl" <<EOF
#!/bin/sh
prev=""
out=""
for a in "\$@"; do
  if [ "\$prev" = "-o" ]; then out="\$a"; prev=""; continue; fi
  case "\$a" in -o) prev="-o" ;; esac
done
if [ -n "\$out" ]; then
  cp "$ROOT/po0fw.sh" "\$out"
  exit 0
fi
exec "$TEST_TMP/bin/curl" "\$@"
EOF
chmod +x "$TEST_TMP/nonroot-bin/curl"

reset_state
(
  cd "$TEST_TMP/stale-cwd"
  HOME="$FAKE_HOME" \
    XDG_CONFIG_HOME="" \
    XDG_BIN_HOME="" \
    TERMUX_VERSION="" \
    TMPDIR="$TEST_TMP" \
    PATH="$TEST_TMP/nonroot-bin:$PATH" \
    PO0FW_TEST_STATE="$TEST_TMP/state" \
    PO0FW_TOKENS="pgnfw_pipe_install@0" \
    /bin/sh < "$ROOT/install-linux.sh" >/dev/null
)
if grep -q 'STALE_POISON_SCRIPT' "$FAKE_HOME/.local/bin/po0fw"; then
  echo "FAIL: piped installer copied stale ./po0fw.sh from working directory" >&2
  exit 1
fi

echo 'po0fw all shell tests passed'
