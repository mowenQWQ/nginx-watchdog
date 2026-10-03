#!/bin/sh
# =============================================================================
# nginx-watchdog.sh — 通用 nginx 自愈看门狗（BT/宝塔 与非宝塔环境通用）
#
# 作用：周期性检查 nginx 是否在正常对外服务；若已彻底死亡，则清理陈旧 pid
#       文件并把它重新拉起。
#
# 背景：见 README.md。典型触发链：
#       unattended-upgrades 每日升级 → needrestart 自动 `systemctl restart nginx`
#       → 停服务时留下残留进程 + pid 文件变空 → init.d 脚本误判"已在运行"拒绝启动
#       → nginx 无人监听 → 站点不可用（且不会自愈，因为 Restart=no）。
#
# 设计要点：
#   1. 只在"确实死了"时动手（否则绝不动 nginx），避免误伤。
#   2. "进程在但端口没起来" 视为半死/异常态，只记日志不硬来（交人工）。
#   3. 拉起前先清空陈旧 pid 文件，绕开 init.d "空 pid 即认为在跑"的缺陷。
#   4. 优先用服务管理器（systemctl）拉起，失败则回退直接调用 nginx 二进制。
#   5. 日志自动截断，长期运行不撑爆磁盘。
#
# 用法：
#   安装到 /usr/local/bin/nginx-watchdog.sh 并加执行权限，
#   再由 systemd timer 或 cron 每分钟调用一次（见 README.md）。
#
# 退出码：0 = 健康或无操作；1 = 尝试了恢复但失败。
# =============================================================================

# ── 可配置项（可用环境变量覆盖） ──────────────────────────────────────────
# 检查哪些端口至少要有一个在监听（默认 80 443）
CHECK_PORTS="${CHECK_PORTS:-80 443}"
# 日志文件
LOG="${LOG:-/var/log/nginx-watchdog.log}"
# pid 文件路径（宝塔默认 /www/server/nginx/logs/nginx.pid；官方包多为 /run/nginx.pid）
PIDFILE="${PIDFILE:-/www/server/nginx/logs/nginx.pid}"
# nginx 二进制（宝塔：/www/server/nginx/sbin/nginx；官方：/usr/sbin/nginx）
NGINX_BIN="${NGINX_BIN:-}"
# nginx 主配置（仅在直接调用二进制回退时使用）
NGINX_CONF="${NGINX_CONF:-}"
# 日志截断阈值（字节）
LOG_MAX_BYTES="${LOG_MAX_BYTES:-262144}"

# ── 内部工具 ──────────────────────────────────────────────────────────────
ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
log() { echo "$(ts) $*" >> "$LOG"; }

# 自动探测 nginx 二进制
detect_bin() {
  [ -n "$NGINX_BIN" ] && [ -x "$NGINX_BIN" ] && return 0
  for c in /www/server/nginx/sbin/nginx /usr/sbin/nginx /usr/local/nginx/sbin/nginx; do
    [ -x "$c" ] && { NGINX_BIN="$c"; return 0; }
  done
  NGINX_BIN="$(command -v nginx 2>/dev/null)"
  [ -n "$NGINX_BIN" ]
}

# 自动探测主配置
detect_conf() {
  [ -n "$NGINX_CONF" ] && [ -f "$NGINX_CONF" ] && return 0
  for c in /www/server/nginx/conf/nginx.conf /etc/nginx/nginx.conf /usr/local/nginx/conf/nginx.conf; do
    [ -f "$c" ] && { NGINX_CONF="$c"; return 0; }
  done
  return 1
}

# 日志轮转：超过阈值就只保留尾部
rotate_log() {
  [ -f "$LOG" ] || return 0
  size=$(wc -c < "$LOG" 2>/dev/null || echo 0)
  if [ "$size" -gt "$LOG_MAX_BYTES" ]; then
    tail -c 65536 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
  fi
}

# 是否还有任意进程名匹配 nginx
nginx_alive() {
  if command -v pidof >/dev/null 2>&1; then
    [ -n "$(pidof nginx 2>/dev/null)" ]
  else
    pgrep -x nginx >/dev/null 2>&1 || ps -eo comm 2>/dev/null | grep -qx nginx
  fi
}

# 目标端口里是否至少有一个在监听。返回 0=有监听。
any_port_listening() {
  for p in $CHECK_PORTS; do
    if command -v ss >/dev/null 2>&1; then
      ss -ltn 2>/dev/null | grep -qE "[:.]${p}[[:space:]]"
    else
      netstat -ltn 2>/dev/null | grep -qE "[:.]${p}[[:space:]]"
    fi && return 0
  done
  return 1
}

# ── 主流程 ────────────────────────────────────────────────────────────────
rotate_log

# 1) 健康：有端口在监听 → 什么都不做
if any_port_listening; then
  exit 0
fi

# 2) 危险：没有端口监听。区分"真死"与"半死"
if nginx_alive; then
  # 进程还在但不监听：可能是重启中/配置异常/端口被占。不硬来。
  log "WARN nginx process alive but no port in [$CHECK_PORTS] listening; manual check needed"
  exit 0
fi

# 3) 真死：清陈旧 pid → 拉起
[ -f "$PIDFILE" ] && rm -f "$PIDFILE"

started=0
if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q '^nginx\.service'; then
  systemctl start nginx >/dev/null 2>&1 && started=1
fi
if [ "$started" -ne 1 ] && detect_bin; then
  if detect_conf; then
    "$NGINX_BIN" -c "$NGINX_CONF" >/dev/null 2>&1 && started=1
  else
    "$NGINX_BIN" >/dev/null 2>&1 && started=1
  fi
fi

if [ "$started" -eq 1 ] && any_port_listening; then
  log "RECOVERED nginx restarted (no port was listening)"
  exit 0
else
  log "FAILED attempted to restart nginx but it is still not serving"
  exit 1
fi
