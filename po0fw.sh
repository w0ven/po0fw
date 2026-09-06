#!/bin/sh
# po0fw - po0 防火墙自动加白（PC / 软路由 / Termux 通用版）
# https://github.com/w0ven/po0fw
#
# 用法:
#   PO0FW_TOKENS="pgnfw_xxx" ./po0fw.sh          # 环境变量方式
#   ./po0fw.sh pgnfw_xxx,pgnfw_yyy@0             # 参数方式（多 token 逗号分割, @N 固定槽位）
#   ./po0fw.sh status                            # 只看状态不加白
#
# 配置文件（可选，优先级低于环境变量/参数）: /etc/po0fw.conf 内容示例:
#   PO0FW_TOKENS="pgnfw_xxx,pgnfw_yyy@0"
#
# API 说明: 使用 po0 官方 IP 直连端点（Let's Encrypt IP 证书）。
#   POST https://124.221.69.228/api/firewall/<token>/add[?slot=N]
# 服务端按来源 IP 自动识别出口 /24 网段并幂等加白（重复不占坑、不推进淘汰），
# 因此本脚本无需自行探测出口 IP，也无需给任何域名配置代理直连分流。

set -u

API_BASE="${PO0FW_API:-https://124.221.69.228/api/firewall}"
CONF="${PO0FW_CONF:-/etc/po0fw.conf}"
CURL_OPTS="-4sS -m 20 --retry 2 --retry-delay 2"

MODE="add"
ARG_TOKENS=""
case "${1:-}" in
  status)
    MODE="status"
    # 允许 `po0fw status pgnfw_xxx` 临时指定 token；省略则回落到环境变量/配置文件
    ARG_TOKENS="${2:-}"
    ;;
  "") ;;
  *) ARG_TOKENS="$1" ;;
esac

# token 来源优先级: 命令行参数 > 环境变量 > 配置文件
TOKENS="${ARG_TOKENS:-${PO0FW_TOKENS:-}}"
if [ -z "$TOKENS" ] && [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF"
  TOKENS="${PO0FW_TOKENS:-}"
fi
if [ -z "$TOKENS" ]; then
  echo "po0fw: 未配置 token。请设置 PO0FW_TOKENS 或写入 $CONF" >&2
  exit 1
fi

log() { echo "[po0fw] $*"; }

# 从 JSON 响应提取 currentIp（形如 45.82.120.0\/24）
json_current_ip() {
  echo "$1" | sed -n 's/.*"currentIp":"\([^"]*\)".*/\1/p' | sed 's|\\/|/|g'
}

# 从 whitelist 数组里逐条抽出 "ip slot"（每行一条，保持服务端返回顺序）。
# slot 为 null 表示普通 FIFO 记录，数字表示被钉死的固定槽位。
json_whitelist_entries() {
  echo "$1" \
    | sed -n 's/.*"whitelist":\[\([^]]*\)\].*/\1/p' \
    | tr '}' '\n' \
    | sed -n 's/.*"ip":"\([^"]*\)"[^"]*"slot":\([^,}]*\).*/\1 \2/p' \
    | sed 's|\\/|/|g'
}

FAIL=0
IDX=0
OLDIFS=$IFS; IFS=','
for entry in $TOKENS; do
  IFS=$OLDIFS
  IDX=$((IDX+1))
  entry=$(echo "$entry" | tr -d ' ')
  [ -z "$entry" ] && continue
  tok=${entry%@*}
  slot=""
  case "$entry" in *@*) slot=${entry##*@} ;; esac
  short=$(echo "$tok" | cut -c1-12)

  if [ "$MODE" = "status" ]; then
    # 只读端点：GET <base>/<token>（不带 /add）。
    # 切勿改回 POST .../add —— 当前 IP 不在白名单时，add 会真的写入并
    # 占掉一个 FIFO 坑位、顶掉最旧记录，status 必须只看不改。
    res=$(curl $CURL_OPTS "$API_BASE/$tok" 2>&1)

    if ! echo "$res" | grep -q '"whitelist"'; then
      log "#$IDX ${short}… ❌ 查询失败: $res"
      FAIL=1
      IFS=','; continue
    fi

    cur=$(json_current_ip "$res")
    limit=$(echo "$res" | sed -n 's/.*"limit":\([0-9]*\).*/\1/p')
    [ -z "$limit" ] && limit=5
    log "#$IDX ${short}… 当前出口 ${cur:-未知}"
    n=0
    hit=0
    entries=$(json_whitelist_entries "$res")
    OLDIFS2=$IFS
    IFS='
'
    for line in $entries; do
      IFS=$OLDIFS2
      ip=${line%% *}
      slotv=${line##* }
      mark="  "
      if [ -n "$cur" ] && [ "$ip" = "$cur" ]; then
        mark="->"
        hit=1
      fi
      case "$slotv" in
        null|"") log "    $mark $ip  (普通，参与 FIFO 淘汰)" ;;
        *)       log "    $mark $ip  (固定槽位 ${slotv}，不淘汰)" ;;
      esac
      n=$((n+1))
      IFS='
'
    done
    IFS=$OLDIFS2
    [ "$n" -eq 0 ] && log "    (白名单为空)"
    log "    共 $n/$limit 个网段占用"
    if [ "$hit" = "1" ]; then
      log "#$IDX ${short}… ✅ 当前出口已在白名单"
    else
      log "#$IDX ${short}… ⚠️  当前出口不在白名单（status 不会自动加白，需要时请跑 po0fw）"
      FAIL=1
    fi
    IFS=','; continue
  fi

  url="$API_BASE/$tok/add"
  [ -n "$slot" ] && url="$url?slot=$slot"
  res=$(curl $CURL_OPTS -X POST "$url" 2>&1)

  if ! echo "$res" | grep -q '"whitelist"'; then
    log "#$IDX ${short}… ❌ 请求失败: $res"
    FAIL=1
    IFS=','; continue
  fi

  cur=$(json_current_ip "$res")
  cur_json=$(echo "$cur" | sed 's|/|\\/|')
  # 验证：响应的 whitelist 数组必须包含 currentIp 对应网段
  if [ -n "$cur" ] && echo "$res" | grep -qF "\"ip\":\"$cur_json\""; then
    log "#$IDX ${short}… ✅ 出口 $cur 已在白名单${slot:+ (槽位 $slot)}"
  else
    log "#$IDX ${short}… ❌ 加白未生效 (currentIp=$cur): $res"
    FAIL=1
  fi
  IFS=','
done
IFS=$OLDIFS

exit $FAIL
