# Edge-side deployment (A2 cloud-edge split)

iSales v1.0 的**边缘**形态：一台 Mac mini 跑 `isales-telephony`（一个进程内包含 modem-controller + audio-bridge + cloud-edge gRPC client + telephony-api loopback），通过云-边 gRPC + 阿里 RTC 与云端 ECS 交互。除媒体面 RTC UDP 出网，**不暴露任何公网端口**。

> 与 openspec change `arch-cloud-edge-split` 的 §11 任务清单一一对应；spec 锚点：
> - `deployment-topology` §边缘 launchd topology
> - `device-hardware` §audio-bridge 与 modem-controller 同进程接口
> - `service-communication` §云-边 gRPC bidi（边缘 client 视角）

## 拓扑

```
┌──────────── Mac mini（macOS 14+）────────────┐
│                                              │
│ launchd 进程：                               │
│   com.isales.telephony                       │
│     ├─ modem-controller (AT + GSM PCM)       │
│     ├─ audio-bridge (ARTC SDK macOS *)       │
│     ├─ cloud-edge gRPC client → ECS:50051    │
│     └─ telephony-api loopback (127.0.0.1)    │
│                                              │
│ 硬件：                                       │
│   USB GSM modem（A7670E 类）→ /dev/tty.usb*  │
│   modem speaker / mic → 系统 sound device    │
│                                              │
│ 状态目录：                                   │
│   ~/Library/Application Support/isales/      │
│     sqlite/edge_buffer.db   离线事件 SQLite  │
│     vendor/                                  │
│       aliyun-artc-macos-python/  ARTC SDK    │
│     recordings/             本地暂存录音     │
│                                              │
│ 配置：                                       │
│   ~/.config/isales/edge.env   （0600 me）    │
│     ISALES_EDGE_DEVICE_ID=edge-01            │
│     ISALES_EDGE_DEVICE_TOKEN=<jwt>           │
│     ISALES_CLOUD_EDGE_URL=                   │
│       cloud.isales.example.com:50051         │
└──────────────────────────────────────────────┘
```

> \* **macOS ARTC SDK Deviation**: 阿里 macOS SDK 是纯 Obj-C Cocoa framework，无 Python wrapper（详见 ~/.claude/projects/-Users-bears-codes-isales/memory/reference_artc_sdk.md）。A2 用 `MacosRtcSession` mock loopback 跑通 wire 形态，**真硬件商用走 D1 Windows 客户端路径**。A2 范围内的"音频通路验收"在 QA 环境用 mock loopback 完成。本 README 的 ARTC SDK 安装步骤为契约占位（任务 8.x 标记 obsolete）。

## 主机依赖

| 类别 | 要求 |
|------|------|
| OS | macOS 14 Sonoma+ (Apple Silicon 或 Intel) |
| Python | `python3.12` via Homebrew (`brew install python@3.12`) |
| 系统包 | Homebrew + git；GSM modem 驱动（通常 macOS 自带 USB-CDC 串口） |
| 用户 | 当前登录用户（launchd LaunchAgent，运行在用户 session 下）|
| 出网 | 443/TCP（gRPC + Let's Encrypt OCSP）+ UDP 公网（阿里 RTC，SDK 自管端口范围）|
| 入网 | 无（不暴露任何公网端口）|

## 快速开始

完整流程见 `../RUNBOOK-edge.md`。最小命令序列：

```bash
# 1. 准备 Mac mini（一次性）
bash deploy/edge/scripts/provision.sh                       # 安装依赖 + 创建目录骨架

# 2. 编辑用户级 env，填 device-id / token / cloud URL
$EDITOR ~/.config/isales/edge.env

# 3. 安装新 release
bash deploy/edge/scripts/install.sh v1.0.0

# 4. 注册 + 启动 launchd
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.isales.telephony.plist
launchctl kickstart -k gui/$UID/com.isales.telephony

# 5. 看日志
log stream --predicate 'subsystem == "isales.telephony"' --info
```

## 子目录索引

| 路径 | 用途 |
|------|------|
| `launchd/com.isales.telephony.plist` | 单一 LaunchAgent，asyncio task group 内包含 modem-controller + audio-bridge + cloud-edge gRPC client + telephony-api loopback |
| `env/edge.env.example` | 用户级 env 模板（device-id / token / cloud URL / RTC AppId） |
| `scripts/install-artc-sdk.sh` | (obsolete per task 8.1) macOS SDK 解压脚本占位；A2 mock 路径不需要 |
| `scripts/install.sh` | git clone + venv + 编译 + 注册 launchd |
| `scripts/rollback.sh` | 切回历史 release symlink + `launchctl kickstart -k` |

## 与单主机 `deploy/macos/` 的差异

- v1 single-host 在 `deploy/macos/` 跑 6 个独立 launchd plist（api / engine / scheduler / worker / telephony-api / modem-controller）。A2 边缘只剩 1 个 `com.isales.telephony` plist，承担所有 telephony 相关角色（单 entry 模式，详见 task 7.1）。
- env 路径从 `/etc/isales/*.env` 改为 `~/.config/isales/edge.env`（LaunchAgent 跑在用户 session）。
- 状态目录从 `/var/lib/isales/` 改为 `~/Library/Application Support/isales/`（用户级路径，macOS 习惯）。

## 不属于本目录的范围

- Windows 边缘原生 backend：D1 `windows-client-core`
- 多租户 / 激活码：C2 `multi-tenant`
- 硬件告警 / 一键诊断：D2 `hardware-observability`
- 数据迁移：A2 上线前现网无客户在跑
