#!/bin/sh
# po0fw Linux / macOS / Termux 一键安装
# 用法: PO0FW_TOKENS="pgnfw_xxx" sh install-linux.sh
#   或: sh install-linux.sh pgnfw_xxx,pgnfw_yyy@0
set -e

TOKENS="${1:-${PO0FW_TOKENS:-}}"
if [ -z "$TOKENS" ]; then
  echo "用法: PO0FW_TOKENS=\"pgnfw_xxx\" sh $0" >&2
  exit 1
fi

RAW_BASE="${PO0FW_RAW:-https://raw.githubusercontent.com/w0ven/po0fw/main}"

# Termux 没有 /usr/bin 写权限，用 $PREFIX
if [ -n "${TERMUX_VERSION:-}" ] || [ -d "/data/data/com.termux" ]; then
  BIN="${PREFIX:-/data/data/com.termux/files/usr}/bin/po0fw"
  CONF="${PREFIX:-/data/data/com.termux/files/usr}/etc/po0fw.conf"
  TERMUX=1
else
  BIN="/usr/local/bin/po0fw"
  CONF="/etc/po0fw.conf"
  TERMUX=0
fi

echo "[1/3] 安装主脚本 -> $BIN"
if [ -f "$(dirname "$0")/po0fw.sh" ]; then
  cp "$(dirname "$0")/po0fw.sh" "$BIN"
else
  curl -sSL -m 30 "$RAW_BASE/po0fw.sh" -o "$BIN"
fi
chmod +x "$BIN"

echo "[2/3] 写配置 -> $CONF"
printf 'PO0FW_TOKENS="%s"\n' "$TOKENS" > "$CONF"
chmod 600 "$CONF"

echo "[3/3] 配置定时任务（每 10 分钟）"
if [ "$TERMUX" = 1 ]; then
  # Termux: 需要 pkg install cronie termux-services 或直接用 crontab
  command -v crontab >/dev/null 2>&1 || pkg install -y cronie >/dev/null
  ( crontab -l 2>/dev/null | grep -v po0fw; echo "*/10 * * * * PO0FW_CONF=$CONF $BIN >/dev/null 2>&1" ) | crontab -
  echo "提示: Termux 需运行 sv-enable crond 或保持 termux 后台运行"
elif command -v systemctl >/dev/null 2>&1 && [ "$(id -u)" = "0" ]; then
  cat > /etc/systemd/system/po0fw.service <<EOF
[Unit]
Description=po0 firewall whitelist updater
After=network-online.target
[Service]
Type=oneshot
ExecStart=$BIN
EOF
  cat > /etc/systemd/system/po0fw.timer <<'EOF'
[Unit]
Description=po0fw every 10 min
[Timer]
OnBootSec=1min
OnUnitActiveSec=10min
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now po0fw.timer
else
  # macOS / 无 systemd: crontab
  ( crontab -l 2>/dev/null | grep -v po0fw; echo "*/10 * * * * PO0FW_CONF=$CONF $BIN >/dev/null 2>&1" ) | crontab -
fi

echo "安装完成，立即执行一次:"
PO0FW_CONF="$CONF" "$BIN"
