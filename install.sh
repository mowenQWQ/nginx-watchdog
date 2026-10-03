#!/bin/sh
# nginx-watchdog installer (systemd timer 版，推荐)
# 用法：sudo sh install.sh
# 卸载：sudo sh install.sh uninstall
set -e

BIN=/usr/local/bin/nginx-watchdog.sh
SVC=/etc/systemd/system/nginx-watchdog.service
TIMER=/etc/systemd/system/nginx-watchdog.timer
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "$1" = "uninstall" ]; then
  systemctl disable --now nginx-watchdog.timer 2>/dev/null || true
  rm -f "$TIMER" "$SVC" "$BIN"
  systemctl daemon-reload 2>/dev/null || true
  echo "nginx-watchdog 已卸载。"
  exit 0
fi

if [ "$(id -u)" != "0" ]; then
  echo "请用 root 运行：sudo sh install.sh" >&2
  exit 1
fi

install -m 0755 "$SRC_DIR/nginx-watchdog.sh" "$BIN"
install -m 0644 "$SRC_DIR/systemd/nginx-watchdog.service" "$SVC"
install -m 0644 "$SRC_DIR/systemd/nginx-watchdog.timer" "$TIMER"
systemctl daemon-reload
systemctl enable --now nginx-watchdog.timer

echo "已安装。状态："
systemctl --no-pager status nginx-watchdog.timer | head -6
echo
echo "日志：tail -f /var/log/nginx-watchdog.log"
echo "（可选）如需限制 needrestart 自动重启，见 needrestart/99-no-auto-restart.conf"
