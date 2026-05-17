## Why

modem-controller 的 `main.py:39` 与 `handlers.py:53` 硬编码 `MockATClient`，导致整套 AI 外呼流水线**至今没有真打通过 GSM modem**——所有归档 change（impl-engine / impl-engine-providers / impl-worker / impl-deploy-macos 等）的"真硬件验证"都是空白，PR #12 12.1 用 A7670E 单测脚本验证过 `ModemDriver.dial()` 跑通，但 `ATClient` Protocol 这一层至今仍是 mock。整套 v1.0 云-边拆分 (A2) / 多角色 PK 商用化都必须建立在"真 modem 能接通真电话"之上，A1 是整条 10-phase 路线的硬地基。

底层物料**全部就绪**：`ModemDriver` + 三家 vendor 子类（A7670 / SIM800C / Quectel）已实装并打通真硬件；`AtClient`（`serial_protocol.py`）的串口 framing + URC 队列已写完；缺的只是把这两层组装成一个实现 `ATClient` Protocol 的 `SerialATClient`，并让 `main.py` 按环境 dispatch。

## What Changes

- **新增 `SerialATClient`**（实装 `at_client.ATClient` Protocol）：构造接收一个 `pyserial` 设备路径 → 内部开 `AtClient` + `detect_driver()` → `dial()` 调 `ModemDriver.dial()` 同时订阅 URC 流，把 `CONNECT` / `NO CARRIER` / `BUSY` / `NO ANSWER` URC 翻译成 `ATEvent(connected|remote_hangup)`，并按 `drivers.HANGUP_CAUSE_MAP` 映射 `cause`；`hangup()` 调 `ModemDriver.hangup()`；`get_signal/iccid/imei` 直接转 `ModemDriver` 方法
- **`main.py` 按环境 dispatch**：默认从 `ISALES_MODEM_SERIAL_PATH`（设备路径，如 `/dev/cu.usbmodem21301` 或 `/dev/ttyUSB0`）+ `ISALES_MODEM_DRIVER`（可选 hint：a7670 / sim800c / quectel_uc20）构造 `SerialATClient`；变量缺省时回退 `MockATClient`（CI / 单元测试 / 无硬件开发环境）
- **`handlers.py` 解除默认 mock**：`build_handlers()` 的 `at_client` 参数仍接收注入的 `ATClient`，但**取消默认 `MockATClient()` 兜底**——调用方必须显式传，避免线上漏配置静默走 mock
- **URC 驱动状态机的真覆盖**：URC 驱动的 `ATEvent` 流通过现有 IPC `connected` / `remote_hangup` 帧上报；GSM hangup_cause 映射在真硬件路径下的语义覆盖（之前只在单元测试 mock 路径验证过）
- **真硬件冒烟测试脚本**：`scripts/at_smoke.py`——给定 tty 路径 + 拨号号码，串起 `SerialATClient.dial → connected → 5s 等待 → hangup`，输出 `ATEvent` 序列；用于 stage-9 上之前回归 + 后续运维抽查
- **配置文档**：在 isales-telephony README 加 modem 接线 → tty 设备发现 → 环境变量 → 启动 modem-controller 的端到端步骤；macOS 与 Linux 各一份

**不在范围**：

- 流式 ASR/LLM/TTS、barge-in、多角色 PK——`impl-engine-providers` 已实装
- 云-边拆分、WebRTC 音频通道——属 A2 `arch-cloud-edge-split`
- Windows 平台 backend、tray app、激活码——属 D1 `windows-client-core`
- SIM 卡热插拔 / 信号告警事件流——`device-hardware` § "udev 自动检测流程" + § "心跳与失联探测" 已实装，本 change 不动
- IPC 帧 / 选号 API / SIM 资料化 schema——已实装且与 AT 通道解耦

## Capabilities

### New Capabilities

（无）

### Modified Capabilities

- `device-hardware`：现 spec § "AT 命令通道" 仅描述 AT 命令 list，未约束 `ATClient` 实现策略；要补 "v1 生产 = `SerialATClient`（pyserial + ModemDriver），开发/CI = `MockATClient`，main 按环境 dispatch" 的 Requirement，并补 URC → `ATEvent` 翻译契约
- `call-state-machine`：状态机已定义 `DIALING → IN_CALL` 等转换，但既有 scenario 是 mock 触发；要补 "真硬件 URC 驱动状态转换" 的 scenario 覆盖，确保 `CONNECT` URC → `IN_CALL`、`NO CARRIER` / `BUSY` URC → `IDLE` + 正确 `hangup_cause`，并约束 ATD 成功 ACK 与 URC 到达之间的状态停留语义

## Impact

- **代码**：isales-telephony 仓 `modem_controller/at_client.py`（新增 `SerialATClient` 类）、`modem_controller/main.py`（env dispatch）、`modem_controller/handlers.py`（取消默认 mock）；新增 `scripts/at_smoke.py`；README 补部署步骤
- **依赖**：无新增 Python 包（`pyserial` / `ModemDriver` / `AtClient` 均已在仓内）
- **配置**：新增两个环境变量 `ISALES_MODEM_SERIAL_PATH`（必填）、`ISALES_MODEM_DRIVER`（可选 hint，缺省自动 detect）；deploy/linux + deploy/macos 的 systemd unit / launchd plist 要补 `EnvironmentVariables`
- **运维**：modem-controller 启动检查需校验 tty 设备可读写；启动失败 = 进程 exit non-zero（不要静默 fall back 到 mock），由 systemd / launchd 守护重启
- **测试**：单元测试用 `MockATClient` 不变；新增 `SerialATClient` 用 pty 模拟串口的集成测试；真硬件冒烟测试归 `scripts/at_smoke.py` 手工跑
- **风险**：URC 时序在不同 modem 固件下有差异（PR #12 12.1 已用 A7670E 验证过，SIM800C / Quectel 在 v1.0 范围内属 best-effort，列入"开放问题"）
