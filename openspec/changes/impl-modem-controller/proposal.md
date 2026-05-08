## Why

阶段 1–5 + 7 已经把 isales-common / isales-api / isales-telephony / isales-scheduler / isales-worker / isales-engine（含真实 LLM/ASR/TTS Provider）/ isales-web 全部跑通；唯独 stage 6 的 **物理硬件接入** 还是空——`device-hardware` spec 描述了 modem-controller 进程职责、AT 命令通道、ALSA PCM 管道、udev 监听、IPC 协议、device 状态机、SIM 资料化管理、hangup_cause 映射，但仓库里没有任何实施。engine 当前只能跑 MockTelephony，没法真打电话；scheduler→engine 拨号链路在 stage 8 端到端联调里第一道就过不去。本 change 把 stage 6 的实施补上，让"开发机插一枚 USB GSM modem 端到端打通自己手机至少 3 轮真实对话"——v1 完成标准 #5——真正达成。

## What Changes

- **新仓 `isales-modem-controller`**（独立 deployable，Linux 守护进程，systemd unit）
  - `modem_controller/at_client.py`：异步 AT 命令客户端（pyserial-asyncio），封装 `ATD<n>;` 拨号 / `ATH` 挂断 / `AT+CSQ` 信号 / `AT+CCID` ICCID / `AT+CGSN` IMEI / `AT+CGREG` 注网状态；命令-响应配对、超时、URC（unsolicited result code）解析（`RING` / `NO CARRIER` / `BUSY` / `+CLIP` 主叫号）
  - `modem_controller/audio_pipe.py`：ALSA PCM 双向管道（pyalsaaudio / `/dev/snd/pcmC*D*c|p`）；上行 8kHz mono 16-bit LE → 重采样 16kHz → IPC；下行 IPC PCM → 重采样 8kHz → ALSA playback；带 jitter buffer（v1 ≤ 200ms，丢帧静音填充）
  - `modem_controller/udev_watcher.py`：pyudev 持续监听 USB add/remove 事件；首次 add 触发 device 注册（IMEI 上报 isales-api `POST /devices`，缺失则 `PATCH /devices/{id}`）+ 标 `detected→registered→idle`；remove 触发 device 状态置 `offline` + 通知 in-call session 走 device_error 清理
  - `modem_controller/ipc_server.py`：Unix socket（`/run/isales/modem.sock`，0660 isales:isales）；按 device-hardware spec § IPC 帧格式 走 newline-delimited JSON 帧（PCM 走 base64 字符串）；engine→modem-controller 指令：`dial / hangup / send_audio_chunk`；modem-controller→engine 事件：`call_state / inbound_audio_chunk / device_error`
  - `modem_controller/recorder.py`：每通通话整段双向 PCM 落本地 wav（`/var/lib/isales/recordings/{call_id}.wav`，stereo 16kHz：左 = 用户上行，右 = AI 下行）；挂断后由 worker 上传 OSS（worker 端 already done in impl-worker）
  - `modem_controller/main.py`：进程入口，启动 udev watcher + ipc server + 心跳到 isales-api（每 30s `PATCH /devices/{id}` last_seen_at）
  - `modem_controller/health.py`：信号弱（CSQ < 8）/ 注网失败标 `flagged`；连续 3 次拨号失败也标 `flagged`
  - `pyproject.toml`：`isales-common`（device/sim_card/transcript schema）+ `pyserial-asyncio` + `pyalsaaudio` + `pyudev` + `httpx`（PATCH /devices）
  - `deploy/`：systemd unit + udev rules（usb modem device 自动 chown isales:dialout）+ /var/lib/isales 目录骨架

- **engine 侧加 `RealTelephonyClient`**
  - `engine/telephony_client.py`：替换 stage 4 的 MockTelephony；连本地 `/run/isales/modem.sock`；封装 `dial(phone, caller_id) -> CallSession`，`hangup()`，`async iter_inbound_audio()`，`send_outbound_audio(chunk)`；统一从 `device_error` 事件抛 `TelephonyDeviceError` → run_loop catch 走 ABNORMAL_END
  - `engine/factory.py`：env `ISALES_TELEPHONY_BACKEND=mock|real` 切换；CI / 本地 mic 测试默认 mock；prod 默认 real
  - 状态机驱动不变：scheduler→engine 拨号 → telephony-api `/devices/select` 选 device → engine 调 RealTelephonyClient.dial → modem-controller AT 拨号 → 接通后双向 PCM 流转 → 状态机 GREETING / SPEAKING / LISTENING / WRAP_UP / END

- **isales-api 端补一个 `last_seen_at` 列 + 心跳端点**
  - `device.last_seen_at TIMESTAMPTZ NULL`（add column migration）
  - `PATCH /devices/{id}/heartbeat`（modem-controller 心跳；只更 last_seen_at + signal_strength）
  - 监控视图：>120s 无心跳的 device 自动 `offline`（worker 定时任务）

- **真硬件验收手册**
  - `docs/HARDWARE_SETUP.md`：A7670 / SIM800C / Quectel UC20 任一型号的开发机接入步骤；udev rules 模板；ALSA card index 自识别脚本

- **测试**
  - `tests/at_client/`：mock serial（aiounittest + asyncio.StreamReader/Writer）跑 ATD/ATH/AT+CSQ/+CLIP URC 完整闭环
  - `tests/audio_pipe/`：mock pyalsaaudio，验证 8↔16kHz 重采样数学正确性（生成 sine wave 验证主频不变）
  - `tests/ipc_server/`：真 Unix socket + 真 length-prefix 帧解码；并发 4 client + dial/hangup 序列
  - `tests/udev_watcher/`：mock pyudev events，验证 add → POST /devices / remove → status=offline 调用
  - `tests/integration/fake-modem/`：纯软件 fake modem（pty pair）模拟 AT 响应 + ALSA loopback；engine ↔ modem-controller IPC 端到端不动真硬件

## Capabilities

### New Capabilities

无。`device-hardware` spec 已经覆盖 modem-controller 全部职责；`service-communication` spec 已经覆盖 engine ↔ modem-controller IPC；`data-model` spec 已经覆盖 device / sim_card / device_sim_binding 表；`call-state-machine` spec 已经覆盖 hangup_cause 映射。本 change 是这些 spec 的**首次完整实施**，与 stage 4 impl-engine 同模式（首次实施不改 requirement）。

### Modified Capabilities

- `device-hardware`: ADD Requirement "modem-controller 心跳与失联探测" — modem-controller MUST 每 30s 向 isales-api `PATCH /devices/{id}/heartbeat`（更 last_seen_at + signal_strength）；isales-worker MUST 每 30s 跑 watchdog，把 last_seen_at > 120s 的 device 置 `offline`。`device.last_seen_at` 已在 `data-model` spec § 表归属与全表清单 中声明，本 change 只是把"如何维护它"补成硬契约。这是对原 spec § device 状态机 "USB 拔出 → offline"兜底链路的扩展（USB 拔出走 udev 即时；进程 crash / 网线掉 走心跳兜底）。

注：原计划同时改 `device-hardware` § IPC 帧格式 与 `service-communication` § 通信通道矩阵，复盘后判定 v1 直接按 spec 现状（NDJSON + base64 PCM；Unix socket 单选）实施即可，无需 spec 改动；length-prefix 与 WebSocket 候选都是 v2 演进路径。

## Impact

- **新仓 isales-modem-controller**：~1500-2000 行 Python；pyproject.toml 引 `pyserial-asyncio` `pyalsaaudio` `pyudev` `httpx` `numpy`（重采样）；deploy/systemd + udev rules
- **isales-engine 仓库改动**：新增 `engine/telephony_client.py`（~200 行）+ factory 增分支；现有 MockTelephony 保留作单元测试 / 本地脱机调试 backend
- **isales-api 仓库改动**：alembic migration 加 `device.last_seen_at`；router 加 `PATCH /devices/{id}/heartbeat`
- **isales-worker 仓库改动**：新增 watchdog job（每 30s 跑），把 last_seen_at > 120s 的 device 标 offline；现有录音上传 job 不动
- **isales-common 不动**：device / sim_card schema 已就位；本 change 用 `last_seen_at` 字段需要 v0.x bump（一个字段，可放 v0.1.4）
- **依赖链**：本 change 完成后 stage 8（端到端联调 + 灰度）所有前置就齐
- **新依赖（系统 / OS）**：Linux + ALSA + udev；硬件 - 1 枚 USB GSM modem（A7670 / SIM800C / Quectel UC20 系列其一）+ 一张可拨打 SIM；macOS / Windows 不能跑（开发机用 fake-modem 走 pty 替代）
- **新环境变量**：
  - `ISALES_MODEM_IPC_PATH`（默认 `/run/isales/modem.sock`）
  - `ISALES_MODEM_SERIAL_PATH`（默认 `/dev/ttyUSB0`，udev 稳定别名 `/dev/ttyUSB-isales-modem`）
  - `ISALES_MODEM_ALSA_CARD`（默认自动识别 USB Audio）
  - `ISALES_MODEM_RECORDING_DIR`（默认 `/var/lib/isales/recordings`）
  - `ISALES_TELEPHONY_BACKEND`（engine 侧 `mock | real`，prod = real）
  - `ISALES_API_BASE_URL`（modem-controller 调 isales-api 心跳）
  - `ISALES_MODEM_AUTH_TOKEN`（modem-controller → isales-api 鉴权 JWT，专用 service account）
- **超出本 change 范围**：
  - 多卡组绑定 / SIM 卡热切（v2，仅一张卡也够 v1 单设备 ≤ 8 路）
  - DTMF 收号 / IVR 菜单（v2，IVR 留待"人工转接"spec 演进）
  - SMS 收发（仅 USSD 余额查询走 AT，不做 SMS）
  - T.38 fax / 视频通话
  - 多主机分布式 modem 农场（v2 候选；spec 已限 v1 单主机 ≤ 8 路）
  - 真账号灰度上线（stage 8 跟进）
