# RUNBOOK — cloud-edge edge side

A2 `arch-cloud-edge-split` 边缘 Mac mini 的运维流程。**云端部分见 `RUNBOOK-cloud.md`**。

> 与 `deploy/edge/` 配套。架构基线见 `openspec/specs/architecture/spec.md` 与 `openspec/specs/device-hardware/spec.md`。

## 目录

1. [边缘机首次配置](#1-边缘机首次配置)
2. [激活码与 Device Token](#2-激活码与-device-token)
3. [常规发版](#3-常规发版)
4. [回滚](#4-回滚)
5. [离线 buffer 排查](#5-离线-buffer-排查)
6. [网络诊断](#6-网络诊断)
7. [硬件诊断](#7-硬件诊断)
8. [日志位置](#8-日志位置)
9. [应急速查](#9-应急速查)

---

## 1. 边缘机首次配置

**前置**：

- macOS 14 Sonoma+，Apple Silicon 或 Intel（v1.0 优先 M2 mini）
- 一颗 USB GSM modem（A7670E / SIM800C / Quectel UC20），SIM 卡有套餐
- 与目标手机号在同一区域的稳定 4G/5G 信号
- 公网出站（443/TCP + UDP 高范围）

**一次性环境**：

```bash
# 1. Homebrew + Python 3.12
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install python@3.12 git

# 2. 创建 release 根目录（需要 sudo 一次）
sudo install -d -o "$USER" -g staff /opt/isales /opt/isales/releases

# 3. clone meta 仓（运维用），里头才有 deploy/edge 脚本
cd ~/codes && git clone https://github.com/tommax-bai/isales.git meta-isales
cd meta-isales

# 4. 跑 install.sh
bash deploy/edge/scripts/install.sh v1.0.0

# 5. 编辑用户级 env
$EDITOR ~/.config/isales/edge.env
# 必填：
#   ISALES_EDGE_DEVICE_ID         由云端 isales-api 后台给出
#   ISALES_EDGE_DEVICE_TOKEN      由 isales-edge-token-mint 签发（见 §2）
#   ISALES_CLOUD_EDGE_URL         cloud.isales.example.com:50051
#   ISALES_MODEM_SERIAL_PATH      `ls /dev/tty.usbserial-*` 找到的串口
# 可选（A2 暂保 mock）：
#   ISALES_AUDIO_BACKEND=mock     真 SDK 待 D1
#   ALIYUN_RTC_APP_ID
#   ALIYUN_RTC_APP_KEY            (engine 已签 token 下发，edge 只需要 AppId 与 token 即可)

# 6. 激活 + 注册 LaunchAgent
bash deploy/edge/scripts/install.sh --activate <release-ts>
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.isales.telephony.plist

# 7. 看进程
launchctl print gui/$UID/com.isales.telephony | head -20
log stream --predicate 'subsystem == "isales.telephony"' --info
```

## 2. 激活码与 Device Token

A2 阶段简化：**云端运维侧用 CLI 签静态长 token**，边缘把它写进 `edge.env`。多租户 / 激活码兑换在 C2 `multi-tenant` 处理。

**云端签 token**：

```bash
# SSH 到云端 ECS
sudo -u isales /opt/isales/current/venv/bin/isales-edge-token-mint \
  --device-id "edge-01" \
  --ttl 365d \
  --signing-secret "$(sudo cat /etc/isales/env/api.env | grep EDGE_TOKEN_SIGNING_SECRET | cut -d= -f2)" \
  > /tmp/edge-01.token

# 看 token 内容（base64 JWT）
cat /tmp/edge-01.token

# 安全传递到边缘机（建议 scp + 立即 shred 源文件）
scp /tmp/edge-01.token user@edge-01.local:~/.config/isales/edge.token
shred -u /tmp/edge-01.token
```

**边缘机写入 env**：

```bash
EDGE_TOKEN=$(cat ~/.config/isales/edge.token)
sed -i.bak "s|^ISALES_EDGE_DEVICE_TOKEN=.*|ISALES_EDGE_DEVICE_TOKEN=$EDGE_TOKEN|" \
  ~/.config/isales/edge.env
rm ~/.config/isales/edge.env.bak ~/.config/isales/edge.token
launchctl kickstart -k gui/$UID/com.isales.telephony
```

**轮换**（建议 6 个月 / 1 年一次）：

1. 云端签新 token（同 device-id）
2. 写入 edge.env
3. `launchctl kickstart -k gui/$UID/com.isales.telephony`
4. 旧 token 立即失效（云端 token 校验拒绝过期签名）

## 3. 常规发版

```bash
cd ~/codes/meta-isales
git pull origin main
bash deploy/edge/scripts/install.sh v1.0.1
bash deploy/edge/scripts/install.sh --activate <new-ts>
# kickstart 已在 --activate 里跑过
```

发版策略：

- 边缘机发版**会断开**云-边 gRPC 流（云端 auto-reconnect 后立即恢复）
- 正在进行的通话**会丢**（modem 自然挂断；scheduler 重试机制接管未完成的 lead）
- 选业务低峰期；如果多台边缘机分批发版，避免同一时刻全部断线

## 4. 回滚

```bash
bash deploy/edge/scripts/rollback.sh --list
bash deploy/edge/scripts/rollback.sh 20260514-220000
```

要点：

- 软链切换 + `launchctl kickstart -k`，~5 s 完成
- SQLite buffer 在 `~/Library/Application Support/isales/sqlite/` 用户目录下，**回滚不丢离线事件**，重连后自动补发
- ARTC SDK vendor 路径（如已用真 SDK）若新 release 缺，回滚后需要手工解压

## 5. 离线 buffer 排查

边缘断网时，`CallEvent` / `HardwareAlert` 暂存到 SQLite。重连后按 seq 顺序补发，weak-ACK 后删除。

```bash
# 看 buffer 当前状态
DB=~/Library/Application\ Support/isales/sqlite/edge_buffer.db
sqlite3 "$DB" "SELECT count(*) FROM events;"
sqlite3 "$DB" "SELECT seq, kind, created_at FROM events ORDER BY seq DESC LIMIT 10;"

# 如积压超出 ISALES_EDGE_SQLITE_RING_CAPACITY，最老的记录被 rotate 掉
sqlite3 "$DB" "SELECT min(seq), max(seq), count(*) FROM events;"
```

**异常清理**（极少情况下用）：

```bash
# 1. 先 stop 进程，避免边写边删
launchctl bootout gui/$UID/com.isales.telephony

# 2. 备份
cp "$DB" "$DB.bak-$(date +%s)"

# 3. 清空 events 表
sqlite3 "$DB" "DELETE FROM events; VACUUM;"

# 4. 重启
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.isales.telephony.plist
```

## 6. 网络诊断

**检查云-边 gRPC 是否通**：

```bash
# 1. DNS + TCP
nc -zv cloud.isales.example.com 50051

# 2. TLS handshake
openssl s_client -connect cloud.isales.example.com:50051 -servername cloud.isales.example.com </dev/null 2>&1 | grep -E "(subject|issuer|Verify return)"

# 3. gRPC ping（用 grpcurl）
brew install grpcurl
grpcurl -H "authorization: Bearer $(grep DEVICE_TOKEN= ~/.config/isales/edge.env | cut -d= -f2)" \
  cloud.isales.example.com:50051 list
```

**检查 RTC UDP**（需要 aliyun RTC SDK 已装；A2 mock 路径下跳过）：

```bash
# SDK 自带 join 测试工具或拷一份 isales-telephony 的 audio_bridge 单元测试本地跑
# 暂时简单方式：看 SDK 文档 / 工单
```

**WAN 抖动监控**（运维可定时跑）：

```bash
mtr -r -c 20 cloud.isales.example.com
```

## 7. 硬件诊断

**modem 串口**：

```bash
# 列 USB 串口
ls /dev/tty.usbserial-*

# 手动跑一次 AT
screen /dev/tty.usbserial-AB0123CD 115200
# 在 screen 里输入：
# AT          → 应回 OK
# AT+CSQ      → 信号强度
# AT+CPIN?    → SIM 状态
# 退出 Ctrl-A K Y
```

**modem 切换**：

```bash
# 拔插 USB 后串口路径可能变
ls /dev/tty.usbserial-*
$EDITOR ~/.config/isales/edge.env  # 更新 ISALES_MODEM_SERIAL_PATH
launchctl kickstart -k gui/$UID/com.isales.telephony
```

> A2 范围内不提供"自动检测 modem 串口"。这一类 ergonomics 留 D2 `hardware-observability`。

## 8. 日志位置

| 路径 | 用途 |
|------|------|
| `~/Library/Logs/isales/telephony.log` | stdout（业务正常事件） |
| `~/Library/Logs/isales/telephony.err` | stderr（异常 / traceback） |
| `log stream --predicate 'subsystem == "isales.telephony"'` | Apple unified log（结构化） |
| `~/Library/Application Support/isales/sqlite/edge_buffer.db` | 离线事件 SQLite WAL |
| `~/Library/Application Support/isales/recordings/` | 通话录音（worker 上传 OSS 后清理） |

**日志保留**：本目录文件没有自动 rotation。如需要：

```bash
# 简单 cron：每天截断超过 100 MB 的日志
echo '0 3 * * * find ~/Library/Logs/isales -size +100M -exec truncate -s 0 {} \;' | crontab -
```

## 9. 应急速查

| 症状 | 第一动作 |
|------|---------|
| LaunchAgent 不起 | `launchctl print gui/$UID/com.isales.telephony` 看 last exit code |
| gRPC 始终重连失败 | 检查 token 是否过期 / cloud DNS 解析 / 50051 端口可达 |
| 拨号一直 dial_ack 失败 | 检查 modem 串口 + SIM 状态（`AT+CPIN?` `AT+CSQ`）|
| 音频质量差 / 单向 | A2 mock 不验音质；真音频在 D1 |
| 离线 buffer 堆积 | 见 §5 |
| 升级后启动崩 | `bash deploy/edge/scripts/rollback.sh <prev-ts>` |
| 全机失联 | TeamViewer / 远程桌面登入；A2 范围不提供远程一键诊断（D2 处理） |

> 注：本 RUNBOOK 假设运维已熟悉单主机 `deploy/macos/README.md` 与 `RUNBOOK.md` 通用部分（launchd 操作、log stream 用法、macOS 用户权限模型）。
