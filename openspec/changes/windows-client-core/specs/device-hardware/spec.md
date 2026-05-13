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
