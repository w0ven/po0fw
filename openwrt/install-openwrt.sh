#!/bin/sh
# po0fw OpenWrt/Kwrt 一键安装
# 用法: PO0FW_TOKENS="pgnfw_xxx" sh install-openwrt.sh
#   或: sh install-openwrt.sh pgnfw_xxx,pgnfw_yyy@0
set -eu

TOKENS="${1:-${PO0FW_TOKENS:-}}"
if [ -z "$TOKENS" ]; then
  printf '用法: PO0FW_TOKENS="pgnfw_xxx" sh %s\n' "$0" >&2
  exit 1
fi

NORM_TOKENS=$(printf '%s' "$TOKENS" | sed 's/，/,/g; s/、/,/g' | tr '|;\r\n\t ' ',,,,,,' | sed 's/,,*/,/g; s/^,//; s/,$//')
if [ -z "$NORM_TOKENS" ]; then
  printf 'po0fw 安装中止: token 不能为空\n' >&2
  exit 1
fi
OLDIFS=$IFS
IFS=','
for item in $NORM_TOKENS; do
  IFS=$OLDIFS
  tok_part=${item%%@*}
  slot_part=""
  case "$item" in *@*) slot_part=${item#*@} ;; esac
  case "$tok_part" in
    pgnfw_?*)
      case "$tok_part" in
        *[!A-Za-z0-9_-]*)
          printf 'po0fw 安装中止: token "%s" 含非法字符（你是否尚未替换占位符？）\n' "$item" >&2
          exit 1
          ;;
      esac
      ;;
    *)
      printf 'po0fw 安装中止: "%s" 不是有效的 pgnfw_ token\n' "$item" >&2
      exit 1
      ;;
  esac
  if [ -n "$slot_part" ]; then
    case "$slot_part" in
      *[!0-9]*)
        printf 'po0fw 安装中止: 槽位号 "@%s" 必须为非负整数（如 @0）\n' "$item" >&2
        exit 1
        ;;
    esac
  else
    case "$item" in
      *@)
        printf 'po0fw 安装中止: "%s" 的 @ 后缺少槽位号\n' "$item" >&2
        exit 1
        ;;
    esac
  fi
  IFS=','
done
IFS=$OLDIFS

if ! command -v curl >/dev/null 2>&1; then
  printf '[0/4] 未检测到 curl，尝试通过 opkg 安装 curl 与 ca-bundle...\n'
  if command -v opkg >/dev/null 2>&1; then
    opkg update && opkg install curl ca-bundle
  else
    printf 'po0fw 安装中止: 系统缺少 curl，请先手动安装 curl\n' >&2
    exit 1
  fi
fi

RAW_BASE="${PO0FW_RAW:-https://raw.githubusercontent.com/w0ven/po0fw/main}"
BIN="/usr/bin/po0fw"
TMP_BIN="/tmp/po0fw.bin.$$"
trap 'rm -f "$TMP_BIN"' EXIT HUP INT TERM

printf '[1/4] 下载主脚本 -> %s\n' "$BIN"
SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd || pwd)
if [ -f "$SCRIPT_DIR/../po0fw.sh" ]; then
  cp "$SCRIPT_DIR/../po0fw.sh" "$TMP_BIN"
else
  curl -fsSL -m 30 "$RAW_BASE/po0fw.sh" -o "$TMP_BIN"
fi

if [ ! -s "$TMP_BIN" ] || ! head -n 1 "$TMP_BIN" | grep -q '^#!/bin/sh'; then
  printf 'po0fw 安装失败: 下载的主脚本内容无效\n' >&2
  exit 1
fi
chmod 755 "$TMP_BIN"
mv -f "$TMP_BIN" "$BIN"

printf '[2/4] 写配置 -> /etc/po0fw.conf\n'
(
  umask 077
  printf 'PO0FW_TOKENS="%s"\n' "$NORM_TOKENS" > /etc/po0fw.conf
)
chmod 600 /etc/po0fw.conf

printf '[3/4] cron 每 10 分钟兜底\n'
mkdir -p /etc/crontabs
touch /etc/crontabs/root
sed -i '\#/usr/bin/po0fw#d' /etc/crontabs/root
printf '*/10 * * * * /usr/bin/po0fw >/tmp/po0fw.log 2>&1\n' >> /etc/crontabs/root
/etc/init.d/cron enable >/dev/null 2>&1 || true
/etc/init.d/cron restart >/dev/null 2>&1 || /etc/init.d/cron start

printf '[4/4] hotplug 网络变化即时触发\n'
mkdir -p /etc/hotplug.d/iface
cat > /etc/hotplug.d/iface/99-po0fw <<'EOF'
#!/bin/sh
case "$ACTION" in
  ifup) ;;
  ifupdate) [ -n "${IFUPDATE_ADDRESSES:-}" ] || exit 0 ;;
  *) exit 0 ;;
esac
# 忽略纯 IPv6 接口（如 wan6），避免重拨时与 IPv4 wan 重复并发触发
case "$INTERFACE" in
  *6|*6_*) exit 0 ;;
  wan*|wwan*|pppoe*|modem*)
    (sleep 5; /usr/bin/po0fw >/tmp/po0fw.log 2>&1) &
    ;;
esac
EOF
chmod 755 /etc/hotplug.d/iface/99-po0fw

printf '安装完成，立即执行一次:\n'
/usr/bin/po0fw
