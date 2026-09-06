#!/bin/sh
# po0fw OpenWrt/Kwrt 一键安装
# 用法: PO0FW_TOKENS="pgnfw_xxx" sh install-openwrt.sh
#   或: sh install-openwrt.sh pgnfw_xxx,pgnfw_yyy@0
set -e

TOKENS="${1:-${PO0FW_TOKENS:-}}"
if [ -z "$TOKENS" ]; then
  echo "用法: PO0FW_TOKENS=\"pgnfw_xxx\" sh $0" >&2
  exit 1
fi

RAW_BASE="${PO0FW_RAW:-https://raw.githubusercontent.com/w0ven/po0fw/main}"

echo "[1/4] 下载主脚本 -> /usr/bin/po0fw"
if [ -f "$(dirname "$0")/../po0fw.sh" ]; then
  cp "$(dirname "$0")/../po0fw.sh" /usr/bin/po0fw
else
  curl -sSL -m 30 "$RAW_BASE/po0fw.sh" -o /usr/bin/po0fw
fi
chmod +x /usr/bin/po0fw

echo "[2/4] 写配置 -> /etc/po0fw.conf"
cat > /etc/po0fw.conf <<EOF
PO0FW_TOKENS="$TOKENS"
EOF
chmod 600 /etc/po0fw.conf

echo "[3/4] cron 每 10 分钟兜底"
touch /etc/crontabs/root
sed -i '\#/usr/bin/po0fw#d' /etc/crontabs/root
echo "*/10 * * * * /usr/bin/po0fw >/tmp/po0fw.log 2>&1" >> /etc/crontabs/root
/etc/init.d/cron enable >/dev/null 2>&1 || true
/etc/init.d/cron restart >/dev/null 2>&1 || /etc/init.d/cron start

echo "[4/4] hotplug 网络变化即时触发"
mkdir -p /etc/hotplug.d/iface
cat > /etc/hotplug.d/iface/99-po0fw <<'EOF'
#!/bin/sh
[ "$ACTION" = ifup ] || exit 0
case "$INTERFACE" in
  wan*|pppoe*) (sleep 5; /usr/bin/po0fw >/tmp/po0fw.log 2>&1) & ;;
esac
EOF
chmod +x /etc/hotplug.d/iface/99-po0fw

echo "安装完成，立即执行一次:"
/usr/bin/po0fw
