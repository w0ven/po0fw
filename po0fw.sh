#!/bin/sh
# po0fw - po0 防火墙自动加白（PC / 软路由 / Termux 通用版）
# https://github.com/w0ven/po0fw
#
# 用法:
#   PO0FW_TOKENS="pgnfw_xxx" ./po0fw.sh          # 环境变量方式
#   ./po0fw.sh pgnfw_xxx,pgnfw_yyy@0             # 参数方式（多 token 逗号/| 分割, @N 固定槽位）
#   ./po0fw.sh status [pgnfw_xxx]                # 只看状态不加白
#   ./po0fw.sh --help                            # 查看帮助
#
# 配置文件（可选，优先级低于环境变量/参数）:
#   /etc/po0fw.conf 或 ~/.config/po0fw/po0fw.conf
#   内容示例: PO0FW_TOKENS="pgnfw_xxx,pgnfw_yyy@0"
#
# API 说明: 使用 po0 官方 IP 直连端点（Let's Encrypt IP 证书）。
#   POST https://124.221.69.228/api/firewall/<token>/add[?slot=N]
# 服务端按来源 IP 自动识别出口 /24 网段并幂等加白（重复不占坑、不推进淘汰），
# 因此本脚本无需自行探测出口 IP，也无需给任何域名配置代理直连分流。

set -u

PATH="${PATH:+$PATH:}/usr/local/sbin:/usr/local/bin:/opt/homebrew/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

API_BASE="${PO0FW_API:-}"
EXPLICIT_CONF="${PO0FW_CONF:-}"
CURL_BASE_OPTS="-4sS --connect-timeout 10 -m 20"
HTTP_RETRY=3

usage() {
  cat <<'EOF'
用法:
  po0fw                             读取配置并执行加白
  po0fw <tokens>                    使用指定 token 加白（多个用 , 或 | 分隔，可带 @槽位）
  po0fw status [tokens]             只读查询白名单状态（不触发写入或淘汰）
  po0fw -h | --help                 显示此帮助信息

示例:
  po0fw pgnfw_xxx@0,pgnfw_yyy
  PO0FW_TOKENS="pgnfw_xxx" po0fw status
EOF
}

log() { printf '[po0fw] %s\n' "$*"; }

MODE="add"
ARG_TOKENS=""
case "${1:-}" in
  -h|--help|help)
    usage
    exit 0
    ;;
  -*)
    printf 'po0fw: 未知选项: %s\n' "$1" >&2
    usage >&2
    exit 2
    ;;
  status)
    MODE="status"
    case "${2:-}" in
      -h|--help|help)
        usage
        exit 0
        ;;
      -*)
        printf 'po0fw: 未知选项: %s\n' "$2" >&2
        usage >&2
        exit 2
        ;;
      *)
        ARG_TOKENS="${2:-}"
        ;;
    esac
    ;;
  "") ;;
  *) ARG_TOKENS="$1" ;;
esac

# 安全解析配置文件（纯文本解析，不执行任意 shell 命令）
# 同时兼容 PO0FW_TOKENS="pgnfw_xxx" 键值写法与纯 token 行写法
CONF_TOKENS=""
CONF_API=""
parse_conf_file() {
  conf_file="$1"
  [ -f "$conf_file" ] && [ -r "$conf_file" ] || return 1
  while IFS= read -r raw_line || [ -n "$raw_line" ]; do
    line=$(printf '%s' "$raw_line" | tr -d '\r')
    # 去首尾空白
    line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    case "$line" in
      ""|\#*) continue ;;
      export\ PO0FW_TOKENS=*|PO0FW_TOKENS=*)
        val=${line#*PO0FW_TOKENS=}
        val=$(printf '%s' "$val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        case "$val" in
          \"*\") val=${val#\"}; val=${val%\"} ;;
          \'*\') val=${val#\'}; val=${val%\'} ;;
        esac
        CONF_TOKENS="$val"
        ;;
      export\ PO0FW_API=*|PO0FW_API=*)
        val=${line#*PO0FW_API=}
        val=$(printf '%s' "$val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        case "$val" in
          \"*\") val=${val#\"}; val=${val%\"} ;;
          \'*\') val=${val#\'}; val=${val%\'} ;;
        esac
        CONF_API="$val"
        ;;
      pgnfw_*)
        if [ -z "$CONF_TOKENS" ]; then
          CONF_TOKENS="$line"
        else
          CONF_TOKENS="$CONF_TOKENS,$line"
        fi
        ;;
    esac
  done < "$conf_file"
  return 0
}

resolve_conf_path() {
  if [ -n "$EXPLICIT_CONF" ]; then
    printf '%s\n' "$EXPLICIT_CONF"
    return
  fi
  user_conf="${XDG_CONFIG_HOME:-${HOME:-}/.config}/po0fw/po0fw.conf"
  if [ "$(id -u 2>/dev/null || printf 0)" != "0" ] && [ -f "$user_conf" ]; then
    printf '%s\n' "$user_conf"
    return
  fi
  if [ -f "/etc/po0fw.conf" ]; then
    printf '%s\n' "/etc/po0fw.conf"
    return
  fi
  if [ -f "$user_conf" ]; then
    printf '%s\n' "$user_conf"
    return
  fi
  printf '%s\n' "/etc/po0fw.conf"
}

CONF=$(resolve_conf_path)
TOKENS="${ARG_TOKENS:-${PO0FW_TOKENS:-}}"
if [ -z "$TOKENS" ] || [ -z "$API_BASE" ]; then
  parse_conf_file "$CONF" || true
  [ -z "$TOKENS" ] && TOKENS="$CONF_TOKENS"
  [ -z "$API_BASE" ] && API_BASE="$CONF_API"
fi
API_BASE="${API_BASE:-https://124.221.69.228/api/firewall}"

if [ -z "$TOKENS" ]; then
  printf 'po0fw: 未配置 token。请设置 PO0FW_TOKENS 或写入 %s\n' "$CONF" >&2
  exit 1
fi

# 并发防抖锁：避免 OpenWrt 多接口 hotplug 与 cron 同一时刻并发踩踏
LOCK_DIR=""
cleanup_lock() {
  if [ -n "$LOCK_DIR" ] && [ -d "$LOCK_DIR" ]; then
    rm -rf "$LOCK_DIR" 2>/dev/null || true
  fi
}

if [ "$MODE" = "add" ]; then
  candidate_lock="${TMPDIR:-/tmp}/po0fw-$(id -u 2>/dev/null || printf 0).lock"
  if ! mkdir "$candidate_lock" 2>/dev/null; then
    old_pid=""
    [ -f "$candidate_lock/pid" ] && old_pid=$(cat "$candidate_lock/pid" 2>/dev/null || true)
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
      # 短暂等待前序实例自然结束；若仍在运行则礼貌跳过本次重复触发
      waited=0
      while [ "$waited" -lt 3 ] && [ -d "$candidate_lock" ] && kill -0 "$old_pid" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
      done
      if ! mkdir "$candidate_lock" 2>/dev/null; then
        log "已有实例正在运行 (PID ${old_pid})，跳过本次重复触发"
        exit 0
      fi
    else
      rm -rf "$candidate_lock" 2>/dev/null || true
      mkdir "$candidate_lock" 2>/dev/null || candidate_lock=""
    fi
  fi
  if [ -n "$candidate_lock" ] && [ -d "$candidate_lock" ]; then
    LOCK_DIR="$candidate_lock"
    printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
    trap cleanup_lock EXIT HUP INT TERM
  fi
fi

# 规范化单行 JSON 并还原转义斜杠 \/ -> /
normalize_json() {
  printf '%s' "$1" | tr -d '\r\n' | sed 's#\\\\*/#/#g'
}

json_current_ip() {
  printf '%s\n' "$1" | sed -n 's/.*"currentIp"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

json_limit() {
  printf '%s\n' "$1" | sed -n 's/.*"limit"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p'
}

json_is_disabled() {
  printf '%s\n' "$1" | grep -q '"enabled"[[:space:]]*:[[:space:]]*false'
}

json_error_message() {
  msg=$(printf '%s\n' "$1" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  [ -z "$msg" ] && msg=$(printf '%s\n' "$1" | sed -n 's/.*"error"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  printf '%s\n' "$msg"
}

# 从 whitelist 数组逐条抽出 "ip slot"（与字段顺序及额外字段无关）
json_whitelist_entries() {
  arr=$(printf '%s\n' "$1" | sed -n 's/.*"whitelist"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p')
  [ -z "$arr" ] && return 0
  printf '%s\n' "$arr" | tr '}' '\n' | while IFS= read -r chunk || [ -n "$chunk" ]; do
    ip=$(printf '%s\n' "$chunk" | sed -n 's/.*"ip"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    if [ -z "$ip" ]; then
      # 兼容旧版纯字符串数组 ["203.0.113.0/24"]
      ip=$(printf '%s\n' "$chunk" | sed -n 's/.*"\([0-9][0-9.]*\(\/[0-9][0-9]*\)*\)".*/\1/p')
    fi
    [ -z "$ip" ] && continue
    slotv=$(printf '%s\n' "$chunk" | sed -n 's/.*"slot"[[:space:]]*:[[:space:]]*\([^,[:space:]]*\).*/\1/p')
    [ -z "$slotv" ] && slotv="null"
    printf '%s %s\n' "$ip" "$slotv"
  done
}

# 比较两个 IP 或 /24 网段是否落在同一 C 段
same_c24() {
  a="$1"
  b="$2"
  [ -n "$a" ] && [ -n "$b" ] || return 1
  [ "$a" = "$b" ] && return 0
  case "$a|$b" in
    */24*|*\|*/24) ;;
    *) return 1 ;;
  esac
  a_base=${a%/24}
  b_base=${b%/24}
  a_p3=${a_base%.*}
  b_p3=${b_base%.*}
  # 确保确实是 4 段点分 IPv4
  case "$a_base" in
    [0-9]*.[0-9]*.[0-9]*.[0-9]*) ;;
    *) return 1 ;;
  esac
  case "$b_base" in
    [0-9]*.[0-9]*.[0-9]*.[0-9]*) ;;
    *) return 1 ;;
  esac
  [ "$a_p3" = "$b_p3" ]
}

# 判断服务端响应是否属于可自愈的瞬时错误（网络失败 / 5xx / 非 JSON 的裸 400 "Error"）
is_retryable_response() {
  rc="$1"
  code="$2"
  body="$3"
  [ "$rc" -ne 0 ] && return 0
  case "$code" in
    ""|000|5[0-9][0-9]|429) return 0 ;;
    2[0-9][0-9]|403) return 1 ;;
  esac
  # 其他 4xx：若返回规范 JSON 错误（如 {"code":400,...}）属确定性错误不重试；裸文本（如 "Error"）则重试
  trimmed=$(printf '%s' "$body" | tr -d '\r\n' | sed 's/^[[:space:]]*//')
  case "$trimmed" in
    \{*) return 1 ;;
    *) return 0 ;;
  esac
}

HTTP_BODY=""
HTTP_CODE=""
HTTP_ERR=""
http_request() {
  method="$1"
  url="$2"
  attempt=1
  while :; do
    HTTP_BODY=""
    HTTP_CODE=""
    HTTP_ERR=""
    if [ "$method" = "POST" ]; then
      # shellcheck disable=SC2086
      raw=$(curl $CURL_BASE_OPTS -X POST -w '\n__HTTP_STATUS__:%{http_code}' "$url" 2>&1)
      rc=$?
    else
      # shellcheck disable=SC2086
      raw=$(curl $CURL_BASE_OPTS -w '\n__HTTP_STATUS__:%{http_code}' "$url" 2>&1)
      rc=$?
    fi

    case "$raw" in
      *__HTTP_STATUS__:*)
        HTTP_CODE=${raw##*__HTTP_STATUS__:}
        HTTP_CODE=$(printf '%s' "$HTTP_CODE" | tr -d '\r\n ')
        HTTP_BODY=${raw%__HTTP_STATUS__:*}
        # 去掉 -w 注入的前导换行
        HTTP_BODY=$(printf '%s' "$HTTP_BODY" | sed '$s/\r$//')
        ;;
      *)
        HTTP_BODY="$raw"
        HTTP_CODE="000"
        ;;
    esac

    # 兼容测试桩中未解析 -w 参数的简化 mock curl（rc=0 且 body 已含 JSON）
    if [ "$rc" -eq 0 ] && [ "$HTTP_CODE" = "000" ]; then
      case "$HTTP_BODY" in
        *'"whitelist"'*|*'"code"'*) HTTP_CODE="200" ;;
      esac
    fi

    if ! is_retryable_response "$rc" "$HTTP_CODE" "$HTTP_BODY"; then
      [ "$rc" -ne 0 ] && HTTP_ERR="$HTTP_BODY"
      return 0
    fi

    if [ "$attempt" -ge "$HTTP_RETRY" ]; then
      if [ "$rc" -ne 0 ]; then
        HTTP_ERR="${HTTP_BODY}（已重试 ${HTTP_RETRY} 次）"
      fi
      return 0
    fi

    sleep "$attempt"
    attempt=$((attempt + 1))
  done
}

# 将各种常见分隔符（英文/中文逗号、竖线、分号、顿号、空白）统一为空格切分
NORMALIZED_TOKENS=$(printf '%s' "$TOKENS" | sed 's/，/ /g; s/、/ /g' | tr ',|;\r\n\t' '      ')

FAIL=0
IDX=0
VALID_COUNT=0
for entry in $NORMALIZED_TOKENS; do
  [ -z "$entry" ] && continue
  IDX=$((IDX + 1))
  tok=${entry%%@*}
  slot=""
  case "$entry" in
    *@*) slot=${entry#*@} ;;
  esac
  short=$(printf '%s' "$tok" | cut -c1-12)

  # 校验 token 与槽位合法性，避免向服务端发送畸形路径或注入查询串
  case "$tok" in
    pgnfw_*[!A-Za-z0-9_-]*|*[!A-Za-z0-9_-]*)
      log "#$IDX ${short}… ❌ 无效 token 格式（含非法字符）"
      FAIL=1
      continue
      ;;
    pgnfw_?*)
      ;;
    *)
      log "#$IDX ${short}… ❌ 无效 token 格式（应以 pgnfw_ 开头）"
      FAIL=1
      continue
      ;;
  esac

  if [ -n "$slot" ]; then
    case "$slot" in
      *[!0-9]*)
        log "#$IDX ${short}… ❌ 无效槽位号 '@$slot'（须为非负整数，如 @0）"
        FAIL=1
        continue
        ;;
    esac
  else
    case "$entry" in
      *@)
        log "#$IDX ${short}… ❌ 槽位号不能为空（如 pgnfw_xxx@0）"
        FAIL=1
        continue
        ;;
    esac
  fi

  VALID_COUNT=$((VALID_COUNT + 1))

  if [ "$MODE" = "status" ]; then
    # 只读端点：GET <base>/<token>（不带 /add）。
    # 切勿改回 POST .../add —— 当前 IP 不在白名单时，add 会真的写入并
    # 占掉一个 FIFO 坑位、顶掉最旧记录，status 必须只看不改。
    http_request "GET" "$API_BASE/$tok"
    norm=$(normalize_json "$HTTP_BODY")

    if [ -n "$HTTP_ERR" ]; then
      log "#$IDX ${short}… ❌ 查询失败: $HTTP_ERR"
      FAIL=1
      continue
    fi
    if [ "$HTTP_CODE" -ge 400 ] 2>/dev/null; then
      err_msg=$(json_error_message "$norm")
      log "#$IDX ${short}… ❌ 查询失败 (HTTP $HTTP_CODE): ${err_msg:-$norm}"
      FAIL=1
      continue
    fi
    if ! printf '%s\n' "$norm" | grep -q '"whitelist"'; then
      log "#$IDX ${short}… ❌ 查询失败: $norm"
      FAIL=1
      continue
    fi

    cur=$(json_current_ip "$norm")
    limit=$(json_limit "$norm")
    [ -z "$limit" ] && limit=5
    log "#$IDX ${short}… 当前出口 ${cur:-未知}"

    if json_is_disabled "$norm"; then
      log "#$IDX ${short}… ⚠️  防火墙未启用"
      FAIL=1
      continue
    fi

    n=0
    hit=0
    entries=$(json_whitelist_entries "$norm")
    OLDIFS=$IFS
    IFS='
'
    for line in $entries; do
      IFS=$OLDIFS
      ip=${line%% *}
      slotv=${line##* }
      mark="  "
      if [ -n "$cur" ] && same_c24 "$ip" "$cur"; then
        mark="->"
        hit=1
      fi
      case "$slotv" in
        null|"") log "    $mark $ip  (普通，参与 FIFO 淘汰)" ;;
        *)       log "    $mark $ip  (固定槽位 ${slotv}，不淘汰)" ;;
      esac
      n=$((n + 1))
      IFS='
'
    done
    IFS=$OLDIFS
    [ "$n" -eq 0 ] && log "    (白名单为空)"
    log "    共 $n/$limit 个网段占用"
    if [ "$hit" = "1" ]; then
      log "#$IDX ${short}… ✅ 当前出口已在白名单"
    else
      log "#$IDX ${short}… ⚠️  当前出口不在白名单（status 不会自动加白，需要时请跑 po0fw）"
      FAIL=1
    fi
    continue
  fi

  url="$API_BASE/$tok/add"
  [ -n "$slot" ] && url="$url?slot=$slot"
  http_request "POST" "$url"
  norm=$(normalize_json "$HTTP_BODY")

  if [ -n "$HTTP_ERR" ]; then
    log "#$IDX ${short}… ❌ 请求失败: $HTTP_ERR"
    FAIL=1
    continue
  fi
  if [ "$HTTP_CODE" = "403" ]; then
    log "#$IDX ${short}… ❌ 槽位冲突：本机 IP 已在其它槽位，请先去控制台删除旧槽位"
    FAIL=1
    continue
  fi
  if [ "$HTTP_CODE" -ge 400 ] 2>/dev/null; then
    err_msg=$(json_error_message "$norm")
    log "#$IDX ${short}… ❌ 请求失败 (HTTP $HTTP_CODE): ${err_msg:-$norm}"
    FAIL=1
    continue
  fi
  if ! printf '%s\n' "$norm" | grep -q '"whitelist"'; then
    log "#$IDX ${short}… ❌ 请求失败: $norm"
    FAIL=1
    continue
  fi
  if json_is_disabled "$norm"; then
    log "#$IDX ${short}… ⚠️  防火墙未启用"
    FAIL=1
    continue
  fi

  cur=$(json_current_ip "$norm")
  entries=$(json_whitelist_entries "$norm")
  matched=0
  OLDIFS=$IFS
  IFS='
'
  for line in $entries; do
    IFS=$OLDIFS
    ip=${line%% *}
    if [ -n "$cur" ] && same_c24 "$ip" "$cur"; then
      matched=1
      break
    fi
    IFS='
'
  done
  IFS=$OLDIFS

  if [ "$matched" = "1" ]; then
    log "#$IDX ${short}… ✅ 出口 $cur 已在白名单${slot:+ (槽位 $slot)}"
  else
    log "#$IDX ${short}… ❌ 加白未生效 (currentIp=${cur:-未知}): $norm"
    FAIL=1
  fi
done

if [ "$IDX" -eq 0 ]; then
  printf 'po0fw: 未解析到有效 token。请检查 PO0FW_TOKENS 或 %s\n' "$CONF" >&2
  exit 1
fi

exit $FAIL
