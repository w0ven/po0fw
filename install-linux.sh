#!/bin/sh
# po0fw Linux / macOS / Termux 一键安装
# 用法: PO0FW_TOKENS="pgnfw_xxx" sh install-linux.sh
#   或: sh install-linux.sh pgnfw_xxx,pgnfw_yyy@0
set -eu

TOKENS="${1:-${PO0FW_TOKENS:-}}"
if [ -z "$TOKENS" ]; then
  printf '用法: PO0FW_TOKENS="pgnfw_xxx" sh %s\n' "$0" >&2
  exit 1
fi

# 预校验 token 格式（防错填占位符或引号破坏配置）
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
        printf 'po0fw 安装中止: 槽位号 "@%s" 必须为非负整数（如 @0）\n' "$slot_part" >&2
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

RAW_BASE="${PO0FW_RAW:-https://raw.githubusercontent.com/w0ven/po0fw/main}"
IS_ROOT=0
[ "$(id -u 2>/dev/null || printf 1)" = "0" ] && IS_ROOT=1

# 路径自适应：Termux 用 $PREFIX；root 用系统目录；macOS / 非 root 普通用户用 ~/.local & ~/.config
if [ -n "${TERMUX_VERSION:-}" ] || [ -d "/data/data/com.termux" ]; then
  BIN="${PREFIX:-/data/data/com.termux/files/usr}/bin/po0fw"
  CONF="${PREFIX:-/data/data/com.termux/files/usr}/etc/po0fw.conf"
  TERMUX=1
elif [ "$IS_ROOT" = "1" ]; then
  BIN="/usr/local/bin/po0fw"
  CONF="/etc/po0fw.conf"
  TERMUX=0
else
  BIN="${XDG_BIN_HOME:-$HOME/.local/bin}/po0fw"
  CONF="${XDG_CONFIG_HOME:-$HOME/.config}/po0fw/po0fw.conf"
  TERMUX=0
fi

BIN_DIR=$(dirname "$BIN")
CONF_DIR=$(dirname "$CONF")
mkdir -p "$BIN_DIR" "$CONF_DIR"

printf '[1/3] 安装主脚本 -> %s\n' "$BIN"
SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd || pwd)
TMP_BIN="${BIN}.tmp.$$"
trap 'rm -f "$TMP_BIN"' EXIT HUP INT TERM

if [ -f "$SCRIPT_DIR/po0fw.sh" ]; then
  cp "$SCRIPT_DIR/po0fw.sh" "$TMP_BIN"
else
  curl -fsSL -m 30 "$RAW_BASE/po0fw.sh" -o "$TMP_BIN"
fi

if [ ! -s "$TMP_BIN" ] || ! head -n 1 "$TMP_BIN" | grep -q '^#!/bin/sh'; then
  printf 'po0fw 安装失败: 下载的主脚本内容无效\n' >&2
  exit 1
fi
chmod 755 "$TMP_BIN"
mv -f "$TMP_BIN" "$BIN"

printf '[2/3] 写配置 -> %s\n' "$CONF"
(
  umask 077
  printf 'PO0FW_TOKENS="%s"\n' "$NORM_TOKENS" > "$CONF"
)
chmod 600 "$CONF"

printf '[3/3] 配置定时任务（每 10 分钟）\n'
CRON_LINE="*/10 * * * * PO0FW_CONF=\"$CONF\" \"$BIN\" >/dev/null 2>&1"
if [ "$TERMUX" = "1" ]; then
  command -v crontab >/dev/null 2>&1 || pkg install -y cronie >/dev/null
  ( crontab -l 2>/dev/null | grep -Fv "$BIN" | grep -v 'po0fw' || true; printf '%s\n' "$CRON_LINE" ) | crontab -
  printf '提示: Termux 需运行 sv-enable crond 或保持 Termux 后台运行\n'
elif command -v systemctl >/dev/null 2>&1 && [ "$IS_ROOT" = "1" ] && [ -d /run/systemd/system ]; then
  cat > /etc/systemd/system/po0fw.service <<EOF
[Unit]
Description=po0 firewall whitelist updater
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
Environment="PO0FW_CONF=$CONF"
ExecStart=$BIN
EOF
  cat > /etc/systemd/system/po0fw.timer <<'EOF'
[Unit]
Description=po0fw every 10 min

[Timer]
OnBootSec=1min
OnUnitActiveSec=10min
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now po0fw.timer
else
  # macOS / 非 root / 无活跃 systemd 的容器或发行版: crontab
  ( crontab -l 2>/dev/null | grep -Fv "$BIN" | grep -v 'po0fw' || true; printf '%s\n' "$CRON_LINE" ) | crontab -
fi

case ":${PATH:-}:" in
  *":$BIN_DIR:"*) ;;
  *)
    printf '提示: %s 当前不在 PATH 中，可直接运行 "%s" 或将该目录加入 PATH\n' "$BIN_DIR" "$BIN"
    ;;
esac

printf '安装完成，立即执行一次:\n'
PO0FW_CONF="$CONF" "$BIN"
