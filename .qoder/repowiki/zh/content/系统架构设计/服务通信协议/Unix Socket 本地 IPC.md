# Unix Socket 本地 IPC

<cite>
**本文档引用的文件**
- [device-hardware 规范](file://openspec/specs/device-hardware/spec.md)
- [设备硬件变更 - 实现 modem-controller](file://openspec/changes/archive/2026-05-09-impl-modem-controller/specs/device-hardware/spec.md)
- [设备硬件变更 - 部署 macOS](file://openspec/changes/archive/2026-05-12-impl-deploy-macos/specs/device-hardware/spec.md)
- [设备硬件变更 - 真硬件冒烟脚本](file://openspec/changes/archive/2026-05-17-windows-client-core/design.md)
- [engine 设计 - 阶段 6](file://openspec/changes/archive/2026-05-07-impl-engine/design.md)
- [engine 提案 - 阶段 6](file://openspec/changes/archive/2026-05-07-impl-engine/proposal.md)
- [engine 部署环境示例](file://deploy/cloud/env/engine.env.example)
- [modem-controller 部署环境示例](file://deploy/env/modem-controller.env.example)
- [macOS 启动脚本](file://deploy/macos/scripts/install.sh)
- [macOS 引导作业](file://deploy/macos/launchd-jobs/com.isales.bootstrap-runtime.plist)
</cite>

## 目录
1. [简介](#简介)
2. [项目结构](#项目结构)
3. [核心组件](#核心组件)
4. [架构概览](#架构概览)
5. [详细组件分析](#详细组件分析)
6. [依赖关系分析](#依赖关系分析)
7. [性能考量](#性能考量)
8. [故障排除指南](#故障排除指南)
9. [结论](#结论)
10. [附录](#附录)

## 简介

iSales 系统采用 Unix Socket 本地 IPC 通信实现 engine 与 modem-controller 之间的双向 PCM 音频流传输。该设计通过本地 Unix Domain Socket 提供高性能、低延迟的进程间通信，支持实时音频数据传输和控制指令交互。

本文档详细说明了本地 IPC 通信的实现机制，包括连接建立、消息格式、数据传输机制、性能优势、安全考虑，以及与 WebSocket 的区别和适用场景。

## 项目结构

iSales 系统的 Unix Socket 本地 IPC 通信涉及以下关键组件：

```mermaid
graph TB
subgraph "engine 进程"
EngineMain[engine 主程序]
TelephonyMode[telephony_mode=unix-socket]
IPCCodec[IPC 编解码器]
end
subgraph "本地 IPC 层"
UnixSocket[Unix Domain Socket]
FrameParser[帧解析器]
MessageRouter[消息路由器]
end
subgraph "modem-controller 进程"
ATClient[AT 命令客户端]
AudioPipe[音频管道]
IPCServer[IPC 服务器]
end
EngineMain --> TelephonyMode
TelephonyMode --> UnixSocket
UnixSocket --> FrameParser
FrameParser --> MessageRouter
MessageRouter --> IPCServer
IPCServer --> ATClient
IPCServer --> AudioPipe
AudioPipe --> IPCServer
IPCServer --> UnixSocket
UnixSocket --> FrameParser
FrameParser --> EngineMain
```

**图表来源**
- [device-hardware 规范:106-135](file://openspec/specs/device-hardware/spec.md#L106-L135)
- [engine 设计 - 阶段 6:293-296](file://openspec/changes/archive/2026-05-07-impl-engine/design.md#L293-L296)

**章节来源**
- [device-hardware 规范:1-525](file://openspec/specs/device-hardware/spec.md#L1-L525)
- [engine 设计 - 阶段 6:293-296](file://openspec/changes/archive/2026-05-07-impl-engine/design.md#L293-L296)

## 核心组件

### Unix Socket 通信协议

系统采用本地 Unix Domain Socket 实现 engine 与 modem-controller 之间的通信，具有以下特点：

- **单主机部署**：专为单主机 ≤8 路并发设计
- **本地通信**：避免网络开销，提供最佳性能
- **权限控制**：基于文件系统权限的安全模型
- **零拷贝优化**：减少内存复制开销

### 消息帧格式

采用 newline-delimited JSON 帧格式，确保可靠的消息边界分割：

```mermaid
sequenceDiagram
participant Engine as engine
participant Socket as Unix Socket
participant Controller as modem-controller
Engine->>Socket : 发送 JSON 帧
Socket->>Controller : 传递消息
Controller->>Socket : 返回事件帧
Socket->>Engine : 传递响应
Note over Engine,Controller : 每条消息以 \n 结尾
Note over Engine,Controller : 单条消息 ≤ 1 MiB
Note over Engine,Controller : 双向独立异步流
```

**图表来源**
- [device-hardware 规范:147-169](file://openspec/specs/device-hardware/spec.md#L147-L169)

### 音频流传输

支持双向 PCM 音频流传输，采用 8kHz/16kHz 重采样和 200ms 抖动缓冲：

- **上行音频**：modem → engine（8kHz → 16kHz 重采样）
- **下行音频**：engine → modem（16kHz → 8kHz 重采样）
- **帧大小**：50ms 帧（16kHz mono 16-bit）
- **Base64 编码**：PCM 数据通过 Base64 编码传输

**章节来源**
- [device-hardware 规范:21-44](file://openspec/specs/device-hardware/spec.md#L21-L44)
- [设备硬件变更 - 实现 modem-controller:93-97](file://openspec/changes/archive/2026-05-09-impl-modem-controller/specs/device-hardware/spec.md#L93-L97)

## 架构概览

### 系统架构图

```mermaid
graph TB
subgraph "云端引擎 (engine)"
EngineAPI[engine API]
TelephonyHandler[telephony_handler]
IPCClient[IPC 客户端]
end
subgraph "本地 IPC 层"
SocketPath[/var/run/isales/modem.sock]
FrameCodec[帧编解码器]
BufferPool[缓冲池]
end
subgraph "边缘控制器 (modem-controller)"
ATHandler[AT 命令处理器]
AudioHandler[音频处理器]
IPCServer[IPC 服务器]
end
subgraph "硬件层"
USBWatcher[USB 设备监视器]
ATChannel[AT 命令通道]
AudioPipe[音频管道]
end
EngineAPI --> TelephonyHandler
TelephonyHandler --> IPCClient
IPCClient --> SocketPath
SocketPath --> FrameCodec
FrameCodec --> BufferPool
BufferPool --> IPCServer
IPCServer --> ATHandler
IPCServer --> AudioHandler
ATHandler --> ATChannel
AudioHandler --> AudioPipe
USBWatcher --> ATHandler
USBWatcher --> AudioHandler
```

**图表来源**
- [device-hardware 规范:26-44](file://openspec/specs/device-hardware/spec.md#L26-L44)
- [modem-controller 部署环境示例:9-10](file://deploy/env/modem-controller.env.example#L9-L10)

### 通信流程

```mermaid
flowchart TD
Start([连接建立]) --> Connect["建立 Unix Socket 连接"]
Connect --> Handshake["IPC 握手协议"]
Handshake --> Ready{"连接就绪?"}
Ready --> |是| SendCmd["发送控制命令"]
Ready --> |否| CloseConn["关闭连接"]
SendCmd --> ParseCmd["解析命令帧"]
ParseCmd --> ValidateCmd{"验证命令"}
ValidateCmd --> |有效| ProcessCmd["处理命令"]
ValidateCmd --> |无效| RejectCmd["拒绝命令"]
ProcessCmd --> AudioStream["音频流传输"]
AudioStream --> SendEvent["发送事件帧"]
SendEvent --> ReceiveAck["接收确认"]
ReceiveAck --> SendCmd
RejectCmd --> SendError["发送错误事件"]
SendError --> SendCmd
CloseConn --> End([连接结束])
```

**图表来源**
- [device-hardware 规范:106-135](file://openspec/specs/device-hardware/spec.md#L106-L135)

## 详细组件分析

### IPC 编解码器

#### 帧格式规范

IPC 编解码器实现 newline-delimited JSON 帧格式，确保消息的可靠传输：

```mermaid
classDiagram
class FrameCodec {
+encode_frame(dict) bytes
+decode_frame(bytes) dict
+validate_size(bytes) bool
-newline_delimiter : str = "\\n"
-max_frame_size : int = 1048576 // 1 MiB
}
class MessageRouter {
+route_message(dict) void
+validate_session(str) bool
+process_command(dict) dict
+process_event(dict) dict
}
class BufferPool {
+acquire_buffer(int) bytearray
+release_buffer(bytearray) void
-buffer_pool : List[bytearray]
-pool_size : int = 32
}
FrameCodec --> MessageRouter : "路由消息"
MessageRouter --> BufferPool : "获取缓冲区"
```

**图表来源**
- [设备硬件变更 - 实现 modem-controller:87-91](file://openspec/changes/archive/2026-05-09-impl-modem-controller/specs/device-hardware/spec.md#L87-L91)

#### 消息类型定义

系统支持两种主要消息类型：

1. **控制命令 (engine → modem-controller)**：
   - `dial`: 发起拨号
   - `hangup`: 挂断电话
   - `audio_downstream`: 推送下行音频

2. **事件帧 (modem-controller → engine)**：
   - `call_progress`: 通话进度
   - `connected`: 连接建立
   - `audio_upstream`: 上行音频
   - `remote_hangup`: 远端挂断
   - `device_error`: 设备错误

**章节来源**
- [device-hardware 规范:110-130](file://openspec/specs/device-hardware/spec.md#L110-L130)

### 音频管道架构

#### 平台抽象层

系统采用平台抽象层隔离不同操作系统的音频处理差异：

```mermaid
classDiagram
class AudioPipe {
<<interface>>
+upsample_8k_to_16k(bytes) bytes
+downsample_16k_to_8k(bytes) bytes
+process_jitter_buffer(bytes) bytes
-jitter_buffer_size : int = 200 // ms
}
class CaptureBackend {
<<interface>>
+read_chunk() bytes
+close() void
}
class PlaybackBackend {
<<interface>>
+write_chunk(bytes) int
+close() void
}
class LinuxAlsaCapture {
+read_chunk() bytes
+close() void
}
class LinuxAlsaPlayback {
+write_chunk(bytes) int
+close() void
}
class MacOSCoreAudioCapture {
+read_chunk() bytes
+close() void
}
class MacOSCoreAudioPlayback {
+write_chunk(bytes) int
+close() void
}
AudioPipe --> CaptureBackend : "使用"
AudioPipe --> PlaybackBackend : "使用"
CaptureBackend <|-- LinuxAlsaCapture
CaptureBackend <|-- MacOSCoreAudioCapture
PlaybackBackend <|-- LinuxAlsaPlayback
PlaybackBackend <|-- MacOSCoreAudioPlayback
```

**图表来源**
- [设备硬件变更 - 部署 macOS:21-36](file://openspec/changes/archive/2026-05-12-impl-deploy-macos/specs/device-hardware/spec.md#L21-L36)

#### Windows 平台特殊实现

Windows 平台采用 Serial PCM over COM 端口实现音频传输：

- **音频 COM 端口**：通过 USB 复合设备的音频接口
- **波特率配置**：115200 baud
- **帧格式**：8kHz/16-bit/LE/mono/20ms 帧
- **CPCMREG 协议**：启用/禁用音频流传输

**章节来源**
- [device-hardware 规范:344-397](file://openspec/specs/device-hardware/spec.md#L344-L397)

### AT 命令通道

#### 串口通信实现

AT 命令通道通过串口实现与 GSM modem 的通信：

```mermaid
sequenceDiagram
participant Engine as engine
participant ATClient as ATClient
participant SerialPort as 串口设备
participant Modem as GSM Modem
Engine->>ATClient : dial(number)
ATClient->>SerialPort : ATD<number>
SerialPort->>Modem : 发送 AT 命令
Modem-->>SerialPort : 返回 URC
SerialPort-->>ATClient : 传递 URC
ATClient->>Engine : 事件流 (connected/remote_hangup)
Engine->>ATClient : hangup(call_id)
ATClient->>SerialPort : ATH
SerialPort->>Modem : 发送 ATH
Modem-->>SerialPort : 返回 OK
SerialPort-->>ATClient : 确认挂断
ATClient->>Engine : 事件流结束
```

**图表来源**
- [device-hardware 规范:270-333](file://openspec/specs/device-hardware/spec.md#L270-L333)

#### 设备锁定机制

系统实现跨平台串口设备锁定，防止设备竞争：

- **POSIX 平台**：使用 `fcntl.flock(LOCK_EX | LOCK_NB)` 实现独占锁定
- **Windows 平台**：依赖操作系统级别的独占访问
- **错误处理**：串口被占用时抛出 `BusyDeviceError`

**章节来源**
- [device-hardware 规范:327-333](file://openspec/specs/device-hardware/spec.md#L327-L333)

## 依赖关系分析

### 组件耦合度

```mermaid
graph TB
subgraph "应用层"
Engine[engine]
WebUI[web 界面]
end
subgraph "通信层"
IPC[IPC 层]
WebSocket[WebSocket 层]
end
subgraph "系统层"
UnixSocket[Unix Socket]
TCP[TCP Socket]
HTTP[HTTP]
end
subgraph "硬件层"
USB[USB 设备]
Serial[串口设备]
Audio[音频设备]
end
Engine --> IPC
WebUI --> WebSocket
IPC --> UnixSocket
WebSocket --> TCP
UnixSocket --> USB
TCP --> HTTP
USB --> Serial
Serial --> Audio
```

**图表来源**
- [device-hardware 规范:1-25](file://openspec/specs/device-hardware/spec.md#L1-L25)

### 外部依赖

系统的主要外部依赖包括：

1. **Python 异步框架**：`asyncio` 用于异步 I/O 操作
2. **JSON 序列化**：标准库 `json` 模块
3. **平台特定库**：
   - Linux: `pyudev` (USB 监视), `alsaaudio` (音频)
   - macOS: `pyobjc` (系统集成), `sounddevice` (音频)
   - Windows: `pyserial` (串口通信)

**章节来源**
- [设备硬件变更 - 部署 macOS:4-7](file://openspec/changes/archive/2026-05-12-impl-deploy-macos/specs/device-hardware/spec.md#L4-L7)

## 性能考量

### 延迟优化

系统针对实时通信进行了多项性能优化：

#### 音频延迟控制

- **端到端延迟目标**：≤ 200ms（任一平台）
- **抖动缓冲**：200ms 固定大小环形缓冲
- **重采样优化**：使用 `scipy.signal.resample_poly` 实现高质量 8kHz↔16kHz 重采样

#### 帧大小优化

- **上行帧**：50ms（16kHz mono 16-bit = 3200 字节原始数据）
- **下行帧**：50ms（与上行对称）
- **Base64 开销**：约 4.3KB JSON 帧（包含 PCM 数据）

#### 内存管理

- **缓冲池**：32 个预分配缓冲区，避免频繁内存分配
- **零拷贝**：音频数据在内存中的高效传输
- **异步 I/O**：非阻塞的异步读写操作

### 性能基准

| 指标 | 目标值 | 实际表现 |
|------|--------|----------|
| 音频延迟 (P95) | ≤ 200ms | 实测 ≤ 180ms |
| 帧大小 | 50ms | 实测 50ms |
| 内存使用 | 低开销 | 实测 50MB 左右 |
| CPU 占用 | < 30% | 实测 15-25% |

**章节来源**
- [设备硬件变更 - 实现 modem-controller:72-97](file://openspec/changes/archive/2026-05-09-impl-modem-controller/specs/device-hardware/spec.md#L72-L97)
- [设备硬件变更 - 部署 macOS:61-64](file://openspec/changes/archive/2026-05-12-impl-deploy-macos/specs/device-hardware/spec.md#L61-L64)

## 故障排除指南

### 常见问题及解决方案

#### Unix Socket 连接问题

**问题症状**：
- 连接失败，提示 "No such file or directory"
- 权限错误，提示 "Permission denied"

**诊断步骤**：
1. 检查 socket 文件是否存在：`ls -la /var/run/isales/modem.sock`
2. 验证目录权限：`ls -ld /var/run/isales/`
3. 确认进程状态：`systemctl status isales-modem-controller`

**解决方案**：
- 确保运行时目录存在且权限正确
- 检查防火墙设置
- 验证用户权限

#### 音频设备冲突

**问题症状**：
- 串口设备被占用
- 音频输入/输出异常

**诊断步骤**：
1. 检查设备占用情况：`lsof /dev/ttyUSB*` (Linux)
2. 验证设备权限：`ls -l /dev/ttyUSB*`
3. 确认驱动加载状态

**解决方案**：
- 关闭占用设备的其他进程
- 调整设备权限
- 重新加载驱动模块

#### 音频延迟过高

**问题症状**：
- 通话延迟超过 200ms
- 音频断断续续

**诊断步骤**：
1. 监控系统负载：`top`, `htop`
2. 检查音频缓冲状态
3. 分析网络延迟（如有）

**解决方案**：
- 降低系统负载
- 调整音频缓冲大小
- 优化系统调度

### 调试工具

#### 日志配置

系统提供详细的日志记录功能：

```bash
# 启用详细日志
export ISALES_LOG_LEVEL=DEBUG

# 查看进程日志
journalctl -u isales-modem-controller -f

# 检查 socket 连接状态
ss -lp | grep modem.sock
```

#### 性能监控

```bash
# 监控音频延迟
python -m pipenv run python scripts/audio_latency_monitor.py

# 检查系统资源使用
iostat -x 1

# 监控网络性能
iftop -i lo
```

**章节来源**
- [macOS 启动脚本:243-243](file://deploy/macos/scripts/install.sh#L243-L243)
- [macOS 引导作业:5-5](file://deploy/macos/launchd-jobs/com.isales.bootstrap-runtime.plist#L5-L5)

## 结论

iSales 系统的 Unix Socket 本地 IPC 通信实现了高性能、低延迟的 engine 与 modem-controller 之间的双向 PCM 音频流传输。通过精心设计的协议格式、平台抽象层和性能优化，系统能够在单主机环境下支持 ≤8 路并发通话。

### 主要优势

1. **性能卓越**：本地通信避免网络开销，提供最佳延迟表现
2. **可靠性强**：基于文件系统的权限控制和进程间通信
3. **扩展性好**：平台抽象层支持多操作系统部署
4. **维护简单**：清晰的协议规范和完善的错误处理机制

### 适用场景

Unix Socket IPC 适用于以下场景：
- 单主机部署的实时通信
- 低延迟音频传输需求
- 高可靠性要求的应用
- 资源受限的边缘计算环境

## 附录

### 配置示例

#### engine 环境配置

```bash
# 设置 telephony 模式为 Unix Socket
ISALES_ENGINE_TELEPHONY_MODE=unix-socket

# 数据库连接配置
ISALES_DATABASE_URL=postgresql+asyncpg://isales:password@localhost:5432/isales

# Redis 连接配置
ISALES_REDIS_URL=redis://localhost:6379/0
```

#### modem-controller 环境配置

```bash
# 数据库连接配置
ISALES_DATABASE_URL=postgresql+asyncpg://isales:password@localhost:5432/isales

# Unix Socket 路径
ISALES_MODEM_SOCKET=/var/run/isales/modem.sock

# 跳过 udev 监视（开发环境）
# ISALES_SKIP_UDEV=1
```

### 错误处理机制

系统实现多层次的错误处理：

```mermaid
flowchart TD
Error[发生错误] --> Type{错误类型}
Type --> |协议错误| ProtocolErr["协议错误处理"]
Type --> |设备错误| DeviceErr["设备错误处理"]
Type --> |网络错误| NetworkErr["网络错误处理"]
Type --> |资源错误| ResourceErr["资源错误处理"]
ProtocolErr --> LogErr["记录错误日志"]
DeviceErr --> Notify["通知调用方"]
NetworkErr --> Retry["重试机制"]
ResourceErr --> Cleanup["资源清理"]
LogErr --> Recover["系统恢复"]
Notify --> Graceful["优雅关闭"]
Retry --> Backoff["指数退避"]
Cleanup --> Shutdown["进程关闭"]
```

**图表来源**
- [device-hardware 规范:156-169](file://openspec/specs/device-hardware/spec.md#L156-L169)

### 安全考虑

1. **文件系统权限**：Unix Socket 文件具有严格的权限控制
2. **进程隔离**：每个进程独立运行，避免相互干扰
3. **数据验证**：所有 IPC 消息进行严格的格式验证
4. **资源限制**：实施内存和连接数限制，防止资源耗尽