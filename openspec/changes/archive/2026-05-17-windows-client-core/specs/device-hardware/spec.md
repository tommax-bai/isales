## ADDED Requirements

### Requirement: Windows 平台 backend

边缘 isales-telephony 进程在 Windows 10 21H2+ / Windows 11（x64）上 SHALL 通过 `isales_telephony/modem_controller/platforms/windows_serial.py`（USB watcher）与 `isales_telephony/modem_controller/audio/windows_serial_pcm.py`（音频 IO）两个 Windows-specific 模块实现。本 Requirement 补完 A2 `arch-cloud-edge-split` 中 "Windows backend 由 D1 提供" 占位。

Windows backend 与 macOS / Linux backend 共享相同的 platform Protocol（`CaptureBackend.read_chunk()`/`close()` 与 `PlaybackBackend.write_chunk()`/`close()`，定义在 `modem_controller/audio_pipe.py`），上层 modem-controller / audio-bridge 业务逻辑 MUST NOT 因平台不同而分支判断。

> **2026-05-17 amend**：原 Requirement 体下的 "WASAPI 音频 backend 默认 Shared Mode" / "音频帧格式" / "USB GSM modem 音频设备路径" 三个 Scenario 基于 "modem 在 Windows 注册 USB Audio Class endpoint" 假设；D1 PoC 实测 SIM7600G-H + Windows 10/11 完全无 USB Audio Class endpoint，假设字面失效。三个 Scenario 由本 amend 反转为 SerialPcm-over-COM 路径，windows_wasapi.py 在 v1.0 不实现。详见 design.md Decision 3 amend + 新增 Decision 8。

#### Scenario: USB watcher 实现策略

- **WHEN** 边缘进程在 Windows 上启动
- **THEN** `windows_serial.py` SHALL：
  - 使用 `serial.tools.list_ports.comports()` 枚举所有 COM 端口
  - 每 1-2 s 轮询一次（与 macOS pyserial polling 频率一致，复用 PR #2 路径）
  - 通过 USB VID:PID 白名单（typical GSM modem 厂商，如华为 / 中兴 / SIMCom）+ AT 试探（向疑似 modem 的 COM 端口发 `AT\r\n`，200 ms 内返回 `OK` 视为命中）联合判定哪个 COM 端口是 GSM modem 的 AT 通道
  - VID:PID 白名单 MAY 通过配置文件扩展，MUST NOT 硬编码到无法外部修改

#### Scenario: 多 COM 端口 modem 识别

- **WHEN** 一个 USB GSM modem 在 Windows 上枚举出多个 COM 端口（AT 通道 / Audio PCM 通道 / 诊断通道 / NMEA 通道，典型如 SIMCom 7600 系列 5-COM composite）
- **THEN** `windows_serial.py` SHALL 用 AT 试探判定 AT 通道（哪个 COM 返回 `OK`）；非 AT 通道 SHALL 不被当作 AT modem 候选；Audio PCM 通道（pyserial `description` 字段含 `Audio` 子串、与 AT 通道同 USB composite serial number / 同 VID:PID）SHALL 被识别并以 `audio_serial_path` 字段随 modem identity 一并 emit，供 SerialPcm backend 构造使用

#### Scenario: SerialPcm-over-COM 音频 backend

- **WHEN** Windows 边缘进程启动音频 capture / playback
- **THEN** `windows_serial_pcm.py` SHALL 通过 `pyserial` 打开 modem 的 audio COM 端口（由 USB watcher 识别得到的 `audio_serial_path`），配置 `baudrate=115200, timeout≈0.020, bytesize=8, parity=N, stopbits=1`；MUST NOT 使用 sounddevice / PortAudio / WASAPI / MME / DirectSound 任何 Windows 音频 API
- audio COM 端口本身 SHALL 在进程启动期一次性 open（与 AT 通道同时），跨所有通话复用同一 file handle；进程退出时 close

#### Scenario: 音频帧格式

- **WHEN** SerialPcm capture 读取或 playback 推流
- **THEN** capture SHALL 以 8 kHz / 16-bit / LE / mono / 20 ms 帧（160 samples = 320 字节）为单位 read；playback SHALL 接受同帧格式 PCM 字节流 write；与 audio-bridge 之间的 8 kHz ↔ 16 kHz 重采样由 `modem_controller/audio_pipe.py` 内既有 `upsample_8k_to_16k` / `downsample_16k_to_8k`（与 macOS / Linux backend 共用路径）完成
- host MUST NOT 假设可通过 AT 命令配置帧格式：SIMCOM SIM7600 系列在主流固件（含本机实测 `LE20B04SIM7600G22`）上 `AT+CPCMFMT=?` 返 `ERROR`，帧格式 modem-fixed；其他兼容 SKU MUST 以同帧约定接入

#### Scenario: USB GSM modem 音频设备路径

- **WHEN** Windows 边缘进程对接 USB GSM modem 音频
- **THEN** v1.0 SHALL 走 **SerialPcm-over-COM** 路径——modem 在 Windows composite USB device 内把 audio 接口（典型 SIMCom MI_04）暴露为 `Class=Ports` 串口而非 USB Audio Class endpoint；host 通过 pyserial 在该 COM 端口 read / write 原始 int16 LE PCM 字节流
- v1.0 MUST NOT 走 "USB Audio Class / WASAPI / sounddevice" 路径：D1 PoC 实测 v1.0 主 SKU SIM7600G-H 在 Windows 上 `Get-PnpDevice -Class AudioEndpoint` 对该 modem 返回 ∅；WASAPI fallback 会静默切到员工 PC 笔记本麦克风/扬声器，构成 silent-wrong 故障模式
- 未来如引入显式注册 USB Audio Class endpoint 的 modem SKU（社区报告华为 E398 / 部分 ZTE MF 系列），MAY 在后续 change 单独评估重引入 WASAPI backend 作并列分支；v1.0 范围 MUST NOT 预留 env / dispatch hook / dual-backend abstraction

#### Scenario: PCM 通道按 SIMCom AT 协议启停（CPCMREG）

- **WHEN** modem 收到 CONNECT URC（call connected）或 NO CARRIER URC（远端挂断）/ 本端 ATH
- **THEN** EdgeOrchestrator 的 `_CallContext` 生命周期 SHALL：
  - 在 connected 之后、`audio_bridge.join_rtc()` 之前发 `AT+CPCMREG=1`（启用 audio COM 端口 PCM 字节流），收到 `OK` 才进入下一步；收到 `ERROR` MUST 上报 `HardwareAlert{kind="pcm_enable_failed"}` 并触发挂断
  - 在 teardown 时 `audio_bridge.leave_rtc()` 之后发 `AT+CPCMREG=0`（释放 PCM 字节流）；该命令失败 SHALL 记 warning log 但 MUST NOT 阻塞 teardown
- audio backend `SerialPcm{Capture,Playback}.read_chunk()` / `write_chunk()` 在 CPCMREG=0 期间自然返回 0 字节 / 超时（pyserial timeout 机制），MUST NOT 抛异常
- `AtClient` SHALL 新增 `cpcmreg_enable()` / `cpcmreg_disable()` 两个 helper，与 `dial()` / `hangup()` 同层；其他 modem SKU 接入时若 AT 协议不同，由 `ModemDriver` 子类 override 这两个 helper

#### Scenario: 音频延迟 SLA

- **WHEN** 边缘进程在 Windows 上跑通常通话
- **THEN** SerialPcm capture / playback 端到端延迟（从 modem mic 采样到 audio-bridge 拿到 PCM；以及反向 audio-bridge push 到 modem speaker 输出）P95 SHALL ≤ 50 ms；如不达标，impl 阶段 MAY 调小 pyserial read timeout 或减小 chunk 帧数；持续不达标 MUST 上报 `HardwareAlert` 并触发挂断

#### Scenario: Windows backend 不影响 macOS / Linux backend

- **WHEN** 实施 D1
- **THEN** `isales_telephony/modem_controller/platforms/macos_*.py` 与 `isales_telephony/modem_controller/audio/{macos_coreaudio,linux_alsa}.py`（已 ship）MUST 不被修改；platform 选择 SHALL 在边缘进程启动时根据 `sys.platform` 自动决定，MUST NOT 通过环境变量强制覆盖

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
