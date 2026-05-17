## ADDED Requirements

### Requirement: Windows 平台 backend

边缘 isales-telephony 进程在 Windows 10 21H2+ / Windows 11（x64）上 SHALL 通过 `isales_telephony/modem_controller/platforms/windows_serial.py` 与 `isales_telephony/audio_pipe/platforms/windows_wasapi.py` 两个 Windows-specific 模块提供 USB watcher 与音频 IO 实现。本 Requirement 补完 A2 `arch-cloud-edge-split` 中 "Windows backend 由 D1 提供" 占位。

Windows backend 与 macOS / Linux backend 共享相同的 platform ABC（`UsbWatcherBackend` / `AudioCaptureBackend` / `AudioPlaybackBackend`），上层 modem-controller / audio-bridge 业务逻辑 MUST NOT 因平台不同而分支判断。

#### Scenario: USB watcher 实现策略

- **WHEN** 边缘进程在 Windows 上启动
- **THEN** `windows_serial.py` SHALL：
  - 使用 `serial.tools.list_ports.comports()` 枚举所有 COM 端口
  - 每 1-2 s 轮询一次（与 macOS pyserial polling 频率一致，复用 PR #2 路径）
  - 通过 USB VID:PID 白名单（typical GSM modem 厂商，如华为 / 中兴 / SIMCom）+ AT 试探（向疑似 modem 的 COM 端口发 `AT\r\n`，200 ms 内返回 `OK` 视为命中）联合判定哪个 COM 端口是 GSM modem 的 AT 通道
  - VID:PID 白名单 MAY 通过配置文件扩展，MUST NOT 硬编码到无法外部修改

#### Scenario: 多 COM 端口 modem 识别

- **WHEN** 一个 USB GSM modem 在 Windows 上枚举出多个 COM 端口（AT 通道 / PCM 通道 / 调试通道，常见于华为 E398 类多模 modem）
- **THEN** `windows_serial.py` SHALL 用 AT 试探判定 AT 通道（哪个 COM 返回 `OK`）；非 AT 通道 SHALL 忽略，MUST NOT 把它们当 modem 候选；PCM 音频在 Windows 上通过另外的设备路径取（见下条 USB Audio Class）而非 PCM 通道 COM 端口

#### Scenario: WASAPI 音频 backend 默认 Shared Mode

- **WHEN** Windows 边缘进程启动音频 capture / playback
- **THEN** `windows_wasapi.py` SHALL 通过 `sounddevice`（PortAudio bindings）开 WASAPI stream；默认 Shared Mode（兼容员工 PC 同时跑微信 / 浏览器 / 视频会议）；MAY 通过 env `ISALES_WASAPI_MODE=exclusive` 切换到 Exclusive Mode（独占设备，延迟更低）；MUST NOT 使用 MME / DirectSound / WDM-KS 等老 API

#### Scenario: 音频帧格式

- **WHEN** WASAPI capture 回调触发或 playback 推流
- **THEN** capture stream SHALL 配置为 16 kHz / 16-bit / mono / 输入帧长由 PortAudio 决定（典型 10-20 ms），audio-bridge 内 chunk 拼接为 20 ms 帧；playback stream SHALL 接受 16 kHz / 16-bit / mono PCM 输入；与 modem 物理通道之间的 8 kHz ↔ 16 kHz 重采样由 audio-bridge 内完成（既有 A2 audio-bridge 重采样路径）

#### Scenario: USB GSM modem 音频设备路径

- **WHEN** Windows 边缘进程对接 USB GSM modem 音频
- **THEN** v1.0 SHALL 走"USB Audio Class"路径（modem 在 Windows 注册为标准音频输入输出设备，通过 sounddevice 列举音频设备 + 名称模糊匹配 / VID:PID 关联选中）；MAY 在后续 change 中补充"串口 PCM 数据帧"路径（兜底给老 modem）；本 change 不强求实现串口 PCM 路径

#### Scenario: 音频延迟 SLA

- **WHEN** 边缘进程在 Windows 上跑通常通话
- **THEN** WASAPI capture / playback 端到端延迟（从 modem mic 采样到 audio-bridge 拿到 PCM；以及反向 audio-bridge push 到 modem speaker 输出）P95 SHALL ≤ 50 ms；如不达标，impl 阶段 MAY 切到 WASAPI Exclusive Mode 或更小的 buffer size；持续不达标 MUST 上报 `HardwareAlert` 并触发挂断

#### Scenario: Windows backend 不影响 macOS / Linux backend

- **WHEN** 实施 D1
- **THEN** `isales_telephony/modem_controller/platforms/macos_*.py` 与 `isales_telephony/audio_pipe/platforms/macos_*.py`（已 ship）MUST 不被修改；platform 选择 SHALL 在边缘进程启动时根据 `sys.platform` 自动决定，MUST NOT 通过环境变量强制覆盖

### Requirement: Windows USB GSM modem 设备识别

modem-controller 在 Windows 上 SHALL 维护一份 USB GSM modem 白名单（厂商 VID + 产品 PID 元组），用于优先识别已知设备；未命中白名单的 COM 端口 SHALL 通过 AT 试探回退识别；MUST NOT 假设所有 COM 端口都是 modem。

#### Scenario: VID:PID 白名单

- **WHEN** 边缘进程枚举 COM 端口
- **THEN** SHALL 优先匹配 USB VID:PID 与白名单（白名单存放在 `isales_telephony/modem_controller/platforms/windows_modem_vendors.toml` 之类的配置）；匹配成功 SHALL 直接将该 COM 端口视为 GSM modem 候选，进入下一步初始化

#### Scenario: AT 试探回退

- **WHEN** 某 COM 端口的 USB VID:PID 不在白名单
- **THEN** modem-controller SHALL 顺序对该端口发 `AT\r\n`，200 ms 内收到包含 `OK` 的响应视为命中（更新本机白名单缓存 + 进入初始化）；超时或返回异常视为非 modem，跳过；试探 SHALL 限频，每个 COM 端口每分钟至多试探一次（避免轮询过载非 modem 设备）

#### Scenario: 设备初始化序列

- **WHEN** 一个 COM 端口被识别为 GSM modem
- **THEN** modem-controller SHALL 顺序发 `AT+CGMI`（厂商）/ `AT+CGMM`（型号）/ `AT+CGSN`（IMEI）/ `AT+CCID`（ICCID）等 AT 命令完成设备元数据登记；初始化失败（无响应 / 错误响应）SHALL 标记 device status = `error` 而非 `idle`，并通过 cloud-edge gRPC 上报 `HardwareAlert{kind="modem_init_failed"}`

## MODIFIED Requirements

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

- **WHEN** 同一串口设备（POSIX 平台 `/dev/ttyUSB*` / `/dev/cu.usbmodem*`；Windows 平台 `COM*` / `\\.\COM*`）被另一个进程已打开
- **THEN** `SerialATClient` 构造时 MUST 通过 platform-appropriate exclusive access 取得独占；任一平台竞争失败 MUST 抛 `BusyDeviceError` 并阻止进程启动；deploy 层 SHALL 确保 modem-controller 单实例
  - POSIX 平台（Linux / macOS）：`fcntl.flock(LOCK_EX | LOCK_NB)` 显式 flock 锁；`BlockingIOError` MUST 翻译为 `BusyDeviceError`
  - Windows 平台：依赖 OS-level exclusive open（`CreateFile` 不带 `FILE_SHARE_*` flag，pyserial 走默认 `dwShareMode = 0`），第二个 open 由 OS 直接拒绝；pyserial 抛出的 access-denied 类异常（`PermissionError` / `SerialException("Access is denied")` / 等价 `OSError(13, ...)`）MUST 由 `SerialATClient.create_from_tty` 单独识别并翻译为 `BusyDeviceError`，其他 open 失败（设备不存在 / 波特率不支持）继续走 `RuntimeError`
- 跨平台抽象 SHALL 通过 `isales_telephony/modem_controller/platforms/serial_lock.py` 提供（`sys.platform` dispatch + lazy import；POSIX 实现持有 fd / Windows 实现返回 no-op handle）；`at_client.py` MUST NOT 在顶层 `import fcntl`（否则 Windows pytest collect 即失败）
