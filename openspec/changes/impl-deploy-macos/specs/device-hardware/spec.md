## ADDED Requirements

### Requirement: 平台抽象层

modem-controller 中所有"接 OS 内核 / 系统驱动"的代码 SHALL 通过 ABC（abstract base class）+ 按 `sys.platform` 选择实现的方式隔离平台特定逻辑。业务代码（状态机、IPC handler、event publisher 等）MUST NOT 直接 import 平台原生绑定（如 `pyudev` / `pyobjc.framework_IOKit` / `alsaaudio`）。

ABC 设计 MUST 不绑死 Linux + macOS 二元——错误类型、事件调度模型、命名约定均 MUST 中立，允许将来扩展第三种实现（如 Windows）而不重构调用方。

#### Scenario: USB 设备监听 ABC

- **WHEN** modem-controller 监听 USB 插拔
- **THEN** SHALL 通过 `modem_controller.platforms.UsbDeviceWatcher` ABC：
  ```python
  class UsbDeviceWatcher(ABC):
      async def start(self) -> None: ...
      async def stop(self) -> None: ...
      def events(self) -> AsyncIterator[UsbAddEvent | UsbRemoveEvent]: ...
  ```
- 事件类型 `UsbAddEvent` / `UsbRemoveEvent` 与 `UsbDeviceWatcherError` MUST 是平台中立的 dataclass / 异常；MUST NOT 暴露 pyudev `Device` 对象 / IOKit `io_object_t` 等原生句柄给调用方

#### Scenario: 音频管道平台抽象

- **WHEN** modem-controller 处理 PCM 双向音频
- **THEN** 抽象 SHALL 分两层：
  - **跨平台 orchestrator** `modem_controller.audio_pipe.AudioPipe`：负责 8kHz↔16kHz 重采样 + 200ms jitter buffer + 上行回调；构造函数接受平台实现的 capture / playback 后端
  - **平台后端 Protocol** `modem_controller.audio.{CaptureBackend, PlaybackBackend}`：raw 8kHz int16 LE mono PCM 的 read_chunk / write_chunk / close 接口
- 业务代码 MUST NOT 直接 import `alsaaudio` / `sounddevice` / `pyserial`；只 import `from .audio import CaptureBackend, PlaybackBackend`；具体实现（`LinuxAlsaCapture` / `LinuxAlsaPlayback` / `MacOSCoreAudioCapture` / `MacOSCoreAudioPlayback`）按平台 dispatch 装载

#### Scenario: 选实现

- **WHEN** modem-controller 启动
- **THEN** `modem_controller.platforms.__init__` 与 `modem_controller.audio.__init__` MUST 按 `sys.platform` 选实现：
  - `linux` → `LinuxUdevWatcher` watcher + `LinuxAlsaCapture` / `LinuxAlsaPlayback` 后端
  - `darwin` → `MacOSIokitWatcher` watcher + `MacOSCoreAudioCapture` / `MacOSCoreAudioPlayback` 后端
  - 其他 → raise `UsbDeviceWatcherError(platform=sys.platform, message="unsupported platform")`
- 启动日志 MUST 打印当前 platform 与选中的 watcher / audio 实现类名

## MODIFIED Requirements

### Requirement: modem-controller 三大职责

modem-controller SHALL 实现以下子系统：USB 设备监听器、AT 命令通道、PCM 音频管道。每个子系统都通过 IPC 暴露给 engine。USB 监听器与 PCM 管道 MUST 通过平台抽象层（见 § 平台抽象层）调用平台原生实现，业务代码不感知平台差异。

#### Scenario: USB 设备监听器

- **WHEN** modem-controller 启动
- **THEN** SHALL 通过 `UsbDeviceWatcher` ABC 持续监听 USB 设备 add / remove 事件，自动同步 device 表状态
  - Linux 实现：用 `pyudev` 订阅 `subsystem='tty'` udev 事件（实时内核 netlink）
  - macOS 实现：用 `pyserial.tools.list_ports.comports()` 在专用 asyncio task 里以 1 Hz 轮询，比对前后两次设备集合的 diff 推导 add / remove 事件（理由：`pyobjc-framework-IOKit` 未在 PyPI 单独发布；ctypes 级 IOKit 调用复杂度过高；GSM modem 插入后到可用需 3–5 秒，1 Hz 轮询时延占比 < 30% 完全可接受）
  - 两种实现 MUST 投递相同的 `UdevEvent` 类型到调用方
  - 如果 1 Hz 轮询时延实测对运维体感不可接受（宿主机重负载下被 starve），允许 follow-up change 引入 ctypes IOKit 通知端口，但接口契约不变

#### Scenario: AT 命令通道

- **WHEN** engine 通过 IPC 请求拨号 / 挂断 / 状态查询
- **THEN** modem-controller SHALL 通过 USB 串口设备发送对应 AT 命令（ATD 拨号、ATH 挂断、AT+CSQ 信号、AT+CCID 卡号、AT+CGSN IMEI 等）；串口设备路径在 Linux 上是 `/dev/ttyUSB*`、在 macOS 上是 `/dev/cu.usbmodem*` / `/dev/cu.usbserial-*`，MUST 通过 `pyserial.tools.list_ports.comports()` 抽象，调用方不硬编码路径前缀

#### Scenario: PCM 音频管道

- **WHEN** 通话建立
- **THEN** modem-controller SHALL 通过 `AudioPipe` ABC 双向流转音频：上行 8kHz 16-bit linear PCM → 重采样 16kHz → engine；下行 engine TTS PCM → 重采样 8kHz → 音频输出
  - Linux 实现：用 ALSA（`alsaaudio` Python 绑定 + `/dev/snd/pcmC*D*c`）
  - macOS 实现：用 `sounddevice`（PortAudio 后端，自动走 Core Audio）
  - **端到端时延基线**：从下行 PCM 写入到对端 modem 听到的时延 MUST ≤ 200ms。任一平台超出该阈值 MUST 阻塞合并，必须排查到达标——不可作为 follow-up 推迟

### Requirement: device 状态机

`device.status` SHALL 在以下状态间转换：

- `unknown` → `detected` → `registered` → `idle` → `dialing` → `in_call` → `idle`
- 任何状态 → `offline`（USB 拔出）
- `idle` / `in_call` → `flagged`（健康度低）
- `detected` → `error`（AT 初始化失败）

#### Scenario: 设备插入后初始化

- **WHEN** USB 监听器（Linux udev 或 macOS IOKit）检测到新 USB 设备且识别为 GSM modem
- **THEN** device.status = `detected`；modem-controller 发 AT 命令初始化；初始化成功后 → `registered` → `idle`

#### Scenario: 拨号期间状态

- **WHEN** engine 调 dial 接口选中某 device
- **THEN** device.status = `dialing` → 接通后 `in_call` → 挂断后 `idle`

#### Scenario: USB 拔出

- **WHEN** USB 监听器检测到 USB 设备拔出（任一平台）
- **THEN** 对应 device 状态 SHALL 立即置 `offline`；正在使用该 device 的 call_session MUST 收到 device_error 事件并优雅清理

#### Scenario: macOS 串口被系统抢占

- **WHEN** macOS 上 GSM modem 设备被系统 modem 服务（`SystemUIServer` / 内核 modem stack）占用
- **THEN** modem-controller 在 `detected` → `registered` 转换中遇到串口打开失败，MUST：
  - 写日志说明端口被占用（建议 `lsof /dev/cu.usbmodem*` 排查）
  - device.status → `error`，等待人工干预或下次插拔
  - RUNBOOK macOS 章节 MUST 提供禁用系统 modem 服务 / 黑名单内核扩展的步骤
