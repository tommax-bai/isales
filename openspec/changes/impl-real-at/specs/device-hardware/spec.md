## ADDED Requirements

### Requirement: ATClient 实现策略

modem-controller SHALL 提供两个 `ATClient` Protocol 实现：`SerialATClient`（v1 生产）与 `MockATClient`（开发 / CI / 无硬件本地调试）。`modem-controller` 进程 MUST 在启动时按环境变量严格 dispatch，MUST NOT 在缺配置时静默回退 mock。

#### Scenario: SerialATClient 为 v1 生产实现

- **WHEN** modem-controller 进程在生产环境启动（systemd unit / launchd plist）
- **THEN** 进程 SHALL 用 `SerialATClient` 实例承担所有 AT 命令通道职责；该实例 MUST 内部持有：
  - 一个 `pyserial` 打开的 `/dev/ttyUSB*`（Linux）或 `/dev/cu.usbmodem*`（macOS）串口
  - 一个 `serial_protocol.AtClient` 实例（低层 framing + URC 队列）
  - 一个由 `drivers.detect_driver()` 选出的 `ModemDriver` 子类实例（A7670 / SIM800C / Quectel UC20）

#### Scenario: env dispatch 与失败语义

- **WHEN** modem-controller 进程启动
- **THEN** 选择 ATClient 实现的 SHALL 严格按以下规则：
  1. 若 `ISALES_MODEM_SERIAL_PATH` 已设置 → 用该路径构造 `SerialATClient`；构造失败（设备不存在 / 权限不够 / 串口被占）MUST 抛异常并 exit 非零
  2. 若 `ISALES_MODEM_SERIAL_PATH` 未设置且 `ISALES_ALLOW_MOCK_AT=1` → 用 `MockATClient` 并打 WARN 日志
  3. 其他情况 → 抛 `RuntimeError` 并 exit 非零
- 进程 MUST NOT 在生产环境（无 `ISALES_ALLOW_MOCK_AT=1`）静默回退 mock

#### Scenario: ISALES_MODEM_DRIVER 提示语义

- **WHEN** `ISALES_MODEM_SERIAL_PATH` 已设置且 `ISALES_MODEM_DRIVER` 可选环境变量已设置（值为 `a7670` / `sim800c` / `quectel_uc20`）
- **THEN** `SerialATClient` 构造时 MUST 把该值作为 hint 传给 `drivers.detect_driver(at, hint=...)`，跳过 `AT+GMI` / `AT+GMM` 自动 detect；hint 未设置时走自动 detect、detect 失败时回落到 `A7670Driver`（保持现行 `detect_driver` 行为）

#### Scenario: handlers 显式注入 ATClient

- **WHEN** `modem_controller.handlers.build_handlers()` 被调用
- **THEN** 函数 MUST 要求显式传 `at_client` 参数；MUST NOT 在 `at_client is None` 时默认构造 `MockATClient()` 兜底（取消 stage-2 兜底逻辑，避免线上漏配置静默走 mock）

### Requirement: URC → ATEvent 翻译契约

`SerialATClient.dial()` SHALL 在 ATD 命令被 modem 接受（OK ACK）后立即返回 `(call_id, AsyncIterator[ATEvent])`；事件流 MUST 由后台协程订阅 `AtClient` 的 URC 通道（通过 `on_urc()` 回调或等价机制）翻译串口 URC 为 `ATEvent` 实例。

#### Scenario: ATD ACK 不触发 connected 事件

- **WHEN** `SerialATClient.dial(number)` 被调用，`ModemDriver.dial()` 返回 `DialResult(connected=True)`
- **THEN** `SerialATClient` MUST NOT 立即 yield `ATEvent("connected", ...)`；MUST 仅返回 `call_id` 与事件流，并等待真正的 CONNECT URC 到达后才 yield connected 事件
- ATD 命令被 modem 拒绝（`DialResult(connected=False)` 含 `hangup_cause`）时 MUST 立即 yield `ATEvent("remote_hangup", call_id, cause=<DialResult.hangup_cause>)` 并结束事件流

#### Scenario: 接通 URC 翻译

- **WHEN** AtClient URC 通道推出表示对端接听的信号（A7670 默认是 `+CIEV` 的语音呼叫激活通知；不同 vendor 可能用 `CONNECT` 等价 token）
- **THEN** 事件流 MUST yield 一次 `ATEvent("connected", call_id)`；同一通话生命周期内 MUST NOT 重复 yield connected；若 vendor 不主动推该 URC（例如某些固件只在响铃后短暂的 OK 之后才推），实现 MAY 用 vendor driver 子类内的 polling 兜底（如周期性 `AT+CLCC` 查询活动呼叫状态），但 SHALL NOT 把 ATD 命令本身的 OK ACK 当作 connected 信号

#### Scenario: 远端挂断 URC 翻译与 cause 映射

- **WHEN** AtClient URC 通道推出 `NO CARRIER` / `BUSY` / `NO ANSWER` / `NO DIALTONE` 等远端挂断 URC
- **THEN** 事件流 MUST 用 `drivers.HANGUP_CAUSE_MAP` 把原始 URC token 映射为 `hangup_cause` 值（见 `isales_common.enums.HangupCause`（`user_hangup` / `user_busy` / `no_answer` / `network_out_of_order` / `temporary_failure` / `normal_clearing` / `call_rejected`）），yield `ATEvent("remote_hangup", call_id, cause=<mapped>)` 并结束事件流；映射缺失 MUST 落到 `network_out_of_order`（保守归类为网络层问题，retry-followup 会触发重试）
- 若需要更精细 cause 区分（如把 `+CEER: 41`（Temporary failure）从 fallback 的 `network_out_of_order` 升级到精确的 `temporary_failure`），driver 子类 MAY 在 URC 到达后异步触发 `AT+CEER` 查询并把 `+CEER` cause code 经 `HANGUP_CAUSE_MAP` 二次映射；该路径属增强能力，v1 不要求

#### Scenario: 本端主动挂断

- **WHEN** `SerialATClient.hangup(call_id)` 被调用
- **THEN** 实现 MUST 调 `ModemDriver.hangup()` 发 ATH / `+CHUP`；事件流 MUST yield `ATEvent("remote_hangup", call_id, cause="manual_hangup")` 并结束；该 cause 值 SHALL 加入 `call-state-machine` 的 hangup_cause enum（见对应 spec delta）

#### Scenario: 串口竞争互斥

- **WHEN** 同一 `/dev/ttyUSB*` 或 `/dev/cu.usbmodem*` 被另一个进程已打开
- **THEN** `SerialATClient` 构造时 MUST 用 `fcntl.flock(LOCK_EX | LOCK_NB)` 拿独占锁；拿不到 MUST 抛 `BusyDeviceError` 并阻止进程启动；deploy 层 SHALL 确保 modem-controller 单实例

### Requirement: 真硬件冒烟脚本

isales-telephony 仓 SHALL 提供 `scripts/at_smoke.py` 用于真硬件端到端冒烟测试。脚本 MUST 不依赖 isales-engine / DB / IPC server，可独立运行以验证 `SerialATClient` 在新部署环境是否打通真 modem。

#### Scenario: 脚本入参与输出

- **WHEN** 运维 / 工程师执行 `python scripts/at_smoke.py --tty <path> --number <phone> [--driver <hint>]`
- **THEN** 脚本 SHALL 构造 `SerialATClient` → 调 `dial(number)` → 把 `ATEvent` 序列打到 stdout（含 `connected` / `remote_hangup` 与 `cause`）→ 接通后等待 5s → 调 `hangup(call_id)` → 等流结束 → exit 0；任何阶段抛异常 → 异常栈打到 stderr → exit 非零
