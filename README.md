# nginx-watchdog

> ⚠️ **AI 使用说明**：本作品由 AI 辅助生成（生成时间：2026-10-04）。仅供学习与参考使用，发布、引用或投入使用前请人工核实关键信息。

[中文](#中文) | [English](#english)

一个极简的 **nginx 自愈看门狗**：每分钟检查 nginx 是否还在对外服务，一旦发现它彻底死亡，就清理陈旧 pid 文件并把它重新拉起。附带一个 **needrestart 防自动重启** 配置，从源头掐断最常见的诱因。

链接：[GitHub](https://github.com/mowenQWQ/nginx-watchdog) ｜ [Gitee 镜像](https://gitee.com/mowenqwq/nginx-watchdog)

---

## 中文

### 它解决什么问题

在 Ubuntu 上，这条链路会悄悄把你的站点搞下线，而且**不会自愈**：

```
unattended-upgrades 每日自动装安全更新
   └─ 升级到 nginx 链接的某个库（例如 libxpm4）
        └─ apt 的 Post-Invoke 钩子调用 needrestart
             └─ needrestart 判定"nginx 用到了新库" → 自动 systemctl restart nginx
                  └─ 若重启时 nginx 因任何原因起不来
                       （BT/宝塔环境尤其常见：停服务留下残留进程 + pid 文件变空，
                         init.d 脚本误判"已在运行"而拒绝启动）
                       └─ nginx 无人监听 → 站点下线，且不会自动恢复
```

关键点：**BT/宝塔的 nginx 由 init.d（LSB）脚本管理，systemd 里是 `Restart=no`** —— 失败一次就永久躺平，没有任何重试。Debian 默认不装 needrestart，所以这个坑**主要落在 Ubuntu 用户身上**。

这不是个例：宝塔/社区里「启动失败、pid 文件不存在 / 已在运行」的报错很常见，根子就是**陈旧或空 pid 文件让 init.d 误判进程仍在**；而「unattended-upgrades 升级 + needrestart 自动重启服务」也是 Ubuntu 上的常见讨论。本次事故正是这两者叠加的结果。

### 两层防御

| 层 | 文件 | 作用 |
|---|---|---|
| **治本** | `needrestart/99-no-auto-restart.conf` | 禁止 needrestart 自动重启服务（只列出、不动作），去掉诱因 |
| **兜底** | `nginx-watchdog.sh` | 不管什么原因挂了，1 分钟内自动拉起 |

两层相互独立：只装看门狗也能救回来；只关 needrestart 能防这一类，但防不了别的死法。**建议都上**。

### 安装

**方式 A：systemd timer（推荐）**

```sh
git clone https://github.com/mowenQWQ/nginx-watchdog && cd nginx-watchdog
sudo sh install.sh
# 卸载：sudo sh install.sh uninstall
```

**方式 B：cron（无 systemd 的环境，或不想加 unit）**

```sh
sudo install -m 0755 nginx-watchdog.sh /usr/local/bin/nginx-watchdog.sh
echo '* * * * * root /usr/local/bin/nginx-watchdog.sh' | sudo tee /etc/cron.d/nginx-watchdog
```

**一并限制 needrestart（可选但推荐）**

```sh
sudo install -m 0644 needrestart/99-no-auto-restart.conf /etc/needrestart/conf.d/99-no-auto-restart.conf
# 验证生效（应输出 l）：
perl -e 'do "/etc/needrestart/needrestart.conf"; do "/etc/needrestart/conf.d/99-no-auto-restart.conf"; print $nrconf{restart},"\n"'
```

### 配置

脚本用环境变量覆盖默认值（systemd 版可写 `/etc/default/nginx-watchdog`）：

| 变量 | 默认 | 说明 |
|---|---|---|
| `CHECK_PORTS` | `80 443` | 至少一个端口在监听即视为健康 |
| `PIDFILE` | `/www/server/nginx/logs/nginx.pid` | 拉起前会清空它 |
| `NGINX_BIN` | 自动探测 | 宝塔 `/www/server/nginx/sbin/nginx`，官方 `/usr/sbin/nginx` |
| `NGINX_CONF` | 自动探测 | 回退直接调用二进制时使用 |
| `LOG` | `/var/log/nginx-watchdog.log` | 事件日志，超 256KB 自动截断 |

### 行为说明（重要，避免误解）

- **健康** → 静默退出，什么都不做。
- **端口不监听但 nginx 进程还在**（半死 / 重启中 / 配置异常）→ **只记一条 WARN，不硬来**。这种情况贸然 kill 可能造成更大问题，交人工判断。
- **进程全没 + 端口不监听**（真死）→ 清陈旧 pid → 依次尝试 `systemctl start nginx`、回退 `nginx -c conf` → 成功记 RECOVERED，失败记 FAILED。

日志样例：

```
2026-10-03T14:37:17Z RECOVERED nginx restarted (no port was listening)
```

### 适用性 / 边界

- 面向**单机 nginx**（含 BT/宝塔、官方包、源码编译）。不处理多实例/集群。
- 它是**安全网，不是根因修复**。若 nginx 反复挂，看门狗只能让它"挂一秒就回来"，治本仍需查根因。
- 想更优雅地自愈，可改用原生 systemd unit + `Restart=on-failure`；但 BT 环境下 unit 走的是 init.d 脚本，仍可能被那个 pid 缺陷卡住——这正是看门狗要先清 pid 的原因。

---

## English

A minimal **self-healing watchdog for nginx**: every minute it checks whether nginx is still serving, and if it has truly died, it clears the stale pid file and brings it back up. Ships with a **needrestart no-auto-restart** config that cuts off the most common trigger at the source.

Links: [GitHub](https://github.com/mowenQWQ/nginx-watchdog) | [Gitee mirror](https://gitee.com/mowenqwq/nginx-watchdog)

### The problem it solves

On Ubuntu this chain can silently take your site down — **and it will not self-heal**:

```
unattended-upgrades installs security updates daily
   └─ upgrades a library nginx links against (e.g. libxpm4)
        └─ apt's Post-Invoke hook runs needrestart
             └─ needrestart decides "nginx uses a new library" → runs systemctl restart nginx
                  └─ if nginx fails to come back for any reason
                       (especially common on BT/aaPanel: stopping the service leaves
                        residual processes + an empty pid file, so the init.d script
                        wrongly thinks it is "already running" and refuses to start)
                       └─ nothing listens → the site is down, and never recovers on its own
```

Key point: **on BT/aaPanel, nginx is managed by an init.d (LSB) script and systemd has `Restart=no`** — one failure means it stays down forever, with no retry. Debian does not ship needrestart by default, so this trap **mostly hits Ubuntu users**.

This is not a one-off: "start failed / pid file does not exist / already running" errors are common in aaPanel and community forums, and the root is always the same — **a stale or empty pid file makes the init.d script believe the process is still alive**; and "unattended-upgrades + needrestart auto-restarting services" is a well-known Ubuntu issue. This incident was the two combined.

### Two layers of defense

| Layer | File | Role |
|---|---|---|
| **Root cause** | `needrestart/99-no-auto-restart.conf` | Stop needrestart from auto-restarting services (list only, take no action) — removes the trigger |
| **Safety net** | `nginx-watchdog.sh` | Whatever the cause, bring nginx back within a minute |

The two are independent: the watchdog alone can still save you; turning off needrestart alone prevents this class of failure but not others. **Install both.**

### Install

**Option A: systemd timer (recommended)**

```sh
git clone https://github.com/mowenQWQ/nginx-watchdog && cd nginx-watchdog
sudo sh install.sh
# uninstall: sudo sh install.sh uninstall
```

**Option B: cron (no systemd, or prefer no unit)**

```sh
sudo install -m 0755 nginx-watchdog.sh /usr/local/bin/nginx-watchdog.sh
echo '* * * * * root /usr/local/bin/nginx-watchdog.sh' | sudo tee /etc/cron.d/nginx-watchdog
```

**Also tame needrestart (optional but recommended)**

```sh
sudo install -m 0644 needrestart/99-no-auto-restart.conf /etc/needrestart/conf.d/99-no-auto-restart.conf
# verify (should print l):
perl -e 'do "/etc/needrestart/needrestart.conf"; do "/etc/needrestart/conf.d/99-no-auto-restart.conf"; print $nrconf{restart},"\n"'
```

### Configuration

Override defaults with environment variables (systemd version: write `/etc/default/nginx-watchdog`):

| Variable | Default | Meaning |
|---|---|---|
| `CHECK_PORTS` | `80 443` | Healthy if at least one of these is listening |
| `PIDFILE` | `/www/server/nginx/logs/nginx.pid` | Cleared before a restart attempt |
| `NGINX_BIN` | auto-detected | aaPanel `/www/server/nginx/sbin/nginx`, official `/usr/sbin/nginx` |
| `NGINX_CONF` | auto-detected | Used only in the direct-binary fallback |
| `LOG` | `/var/log/nginx-watchdog.log` | Event log, auto-truncated past 256 KB |

### Behavior (important — please read)

- **Healthy** → exits silently, does nothing.
- **No port listening but an nginx process exists** (half-dead / restarting / bad config) → **logs one WARN and backs off**. Killing it here could do more harm; hand it to a human.
- **No process and no port** (truly dead) → clears the stale pid → tries `systemctl start nginx`, then falls back to `nginx -c conf` → logs RECOVERED on success, FAILED otherwise.

Sample log:

```
2026-10-03T14:37:17Z RECOVERED nginx restarted (no port was listening)
```

### Scope and boundaries

- For **single-host nginx** (BT/aaPanel, distro packages, source builds). No multi-instance / cluster handling.
- It is a **safety net, not a root-cause fix**. If nginx keeps dying, the watchdog only makes it "die for a second"; the real fix still needs root-cause work.
- For more elegant self-healing you can use a native systemd unit with `Restart=on-failure`; but under BT the unit still runs through the init.d script and can still get stuck on that pid flaw — which is exactly why the watchdog clears the pid first.

---

## 许可 / License

MIT
