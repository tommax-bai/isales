## Context

A2 `arch-cloud-edge-split` 已把 iSales 形态切成「云端 5 服务 + 边缘 modem-controller + audio-bridge」，但 A2 阶段边缘机型默认是 macOS Mac mini——这是 PoC / 内部 QA 形态，**不是商用形态**。

商用形态（v1-roadmap §"边缘交付形态" L106-140 已敲定）：

- 客户员工的 Windows PC（自己买的，型号不限，Windows 10 21H2+ / 11）
- 员工自己插 USB GSM modem 进 PC
- 员工自己装客户端 + 输激活码
- 不依赖工程师上门、不依赖专用边缘机硬件

A2 的 modem_controller / audio_pipe 抽象层（platform backend ABC + asyncio task group + cloud-edge gRPC client）**已经支持平台扩展**——D1 只需补 Windows 平台具体实现：USB watcher（pyserial polling COM 端口）+ 音频 backend（WASAPI）+ 进程托管形态（tray app + 启动注册表）+ 激活码 UX（PySide6 对话框）。

**关键前置**：

- A2 propose 中的 `device-hardware` spec delta 已标注「Windows backend 由 D1 提供」占位
- A2 的 audio-bridge 组件、cloud-edge gRPC client、单进程 asyncio task group 设计与 macOS / Windows 无关
- modem-controller PR #2 落地的 pyserial polling 路径在 Windows 上**原生有效**（pyserial 跨平台库），不用重写

**与 A2 平行推进**：

- 两 change 不互相阻塞：A2 可以先在 macOS 上完成端到端，D1 可以独立在 Windows 机上跑 backend 单测
- spec delta 冲突在 archive 阶段才处理：两份 delta 内容互不重叠（A2 写架构 / macOS / 组件接口，D1 补 Windows 平台细节），merge 是"拼接"而非"调和"

**stakeholder**：

- 产品（你）：确认 Windows 作为 v1.0 首发边缘形态、确认"PyInstaller + pystray + PySide6 + qasync"单 Python 栈方案
- 边缘开发：实现 Windows backend + tray UX + 激活码流程
- 运维 / 商业：拿到 D1 后能给客户发"Windows 客户端 zip + 激活码"的最小化部署包

## Goals / Non-Goals

**Goals**：

1. isales-telephony 在 Windows 10 21H2+ / Windows 11 上以原生 backend 跑通端到端（modem 接通 → 音频上行下行 → cloud-edge gRPC + 阿里 RTC PaaS）
2. 单进程 asyncio + Qt 主循环（qasync）正常工作，task group 异常不阻塞 tray UX
3. 用户体验：开机登录 → tray icon 自动出现 → 首次启动弹激活码对话框 → 输码后客户端正常连云端 → 后续启动直接连
4. PyInstaller frozen exe + ARTC SDK Windows DLL 打包后单文件夹可移植（解压即用）
5. **与 A2 联合 MVP 验收**：员工 Windows PC + GSM modem + 真手机 → 听到 AI 开场白 → 挂断

**Non-Goals**：

- MSI 安装包（D3）
- EV Authenticode 代码签名（D3）
- OTA 自动升级（D3）
- 卸载流程（D3）
- 三态色告警 / 桌面通知 / 一键诊断 GUI（D2）
- 健康检测周期任务 / SIM 余额查询 USSD / 拨号失败率统计（D2）
- 多租户 tenant_id schema / 真正的 activation_token 表 / seat 模型（C2；D1 激活码 = 静态 EDGE_DEVICE_TOKEN）
- macOS / Linux backend 改动（已 ship，本 change 不动）
- 任何云端代码改动（D1 是纯边缘 change）
- Windows ARM64 支持（边缘机绝大多数是 x64，ARM64 留 v2）
- Windows Server 支持（目标用户是员工自带 PC，不是服务器）

## Decisions

### Decision 1：技术栈 = PyInstaller + pystray + PySide6 + qasync 单一 Python 栈

**选项**：

- (A) PyInstaller + pystray + PySide6 + qasync ← **选定**
- (B) 用 C# / .NET 写 tray 壳，Python backend 单独跑 IPC
- (C) 用 Electron / Tauri 写 UI，Python backend IPC
- (D) 用 PyQt6 而非 PySide6

**采纳 (A) 的理由**：

- **零迁移成本**：isales-telephony 整套是 Python 3.12 异步代码 + ARTC SDK Python wrapper + asyncio，新加一层 UI 仍是 Python；不用维护两套语言栈
- **qasync 成熟**：社区 5+ 年，把 Qt event loop 与 asyncio 融合的方案已稳定；不用自己写 thread-bridge / 双 event loop 协调
- **pystray 轻量**：仅做 tray icon + 通知 + menu，跨平台（虽然本 change 只用 Windows）
- **PySide6 vs PyQt6**：PySide6 是 Qt 官方维护 + LGPL，可商用打包不卷许可证；PyQt6 是 Riverbank 维护 GPL/commercial dual license，商用要买 license
- **PyInstaller frozen exe**：单文件夹打包，把 Python 运行时 + 所有依赖 + ARTC SDK DLL 一起塞进去，用户机器无需 Python 环境
- 缺点：frozen exe 启动慢（首次解压 200-500 ms）、防病毒软件可能误报——后者 D3 EV 签名彻底解决，启动慢忽略

**排除 (B) 的理由**：C# tray 壳 + Python backend IPC 多一层进程间通信 / 多一套语言；现有 task group 模型直接套 Python tray 更顺；Windows 部署多 2-3 个二进制产物 + 多语言开发栈。

**排除 (C) 的理由**：Electron / Tauri 装包至少 80-200 MB，与"轻量员工客户端"定位不符；且 UI 复杂度（一个激活码对话框 + 一个二态 tray icon）完全够 PySide6 写。

**排除 (D) 的理由**：PyQt6 商用 license 复杂；PySide6 LGPL 免商用费、Qt 官方维护、API 与 PyQt6 95% 兼容。

### Decision 2：USB watcher = pyserial polling 复用 macOS 同款路径

**选项**：

- (A) pyserial polling（复用 PR #2 macOS 路径，Windows 上原生有效）← **选定 v1.0**
- (B) Windows-specific 触发式：监听 `WM_DEVICECHANGE` 消息 + WMI 查询
- (C) pyudev 风格库（Windows 上没等价物，需 ctypes + Win32 API）

**采纳 (A) 的理由**：

- **代码复用**：macOS 已有的 polling 循环搬过来，COM 端口枚举改用 `serial.tools.list_ports.comports()`（pyserial 自带跨平台 API），识别 USB VID:PID + 试探 `AT` 命令逻辑完全复用
- **CPU 占用低**：典型 1-2 s 轮询，扫一遍 COM 端口 ≤ 10 ms（即使 PC 有 20+ 个虚拟串口）；CPU 占用 < 0.1%
- **Windows 上稳定**：pyserial 在 Windows 上是头部 USB 串口库，长期维护，不踩奇怪边缘情况

**保留 (B) 作未来优化**：如 D2 阶段引入"硬件事件实时性要求"（如 SIM 拔出立即告警），加 `WM_DEVICECHANGE` 触发立即重扫，与 polling 并存（事件触发立即扫一次，polling 兜底）。本 change 不做。

**排除 (C) 的理由**：自己写 ctypes 调 SetupAPI 太重，PR #2 已经验证 pyserial 路径足够好。

**Windows COM 端口约定**：

- USB GSM modem 在 Windows 上典型 enumerate 为 `COM3` / `COM4` / `COM7`（数字不定）
- 多模 modem（如华为 E398）会同时出多个 COM 端口（一个 AT 通道 + 一个 PCM 通道 + 一个调试通道）
- D1 SHALL 通过 USB VID:PID + 顺序尝试 `AT` 试探（如果 VID:PID 在 known modem 列表）来判定哪个 COM 是 AT 通道
- 音频通道在 Windows 上**不是**通过另一个 COM 端口取 PCM，而是通过 modem 在 Windows 注册的 audio device（部分 USB modem 注册为 USB Audio Class 1.0 输入输出设备）→ 见 Decision 3 第 2 段

### Decision 3：音频 backend = SerialPcm-over-COM（MI_04 audio 串口）默认；WASAPI 路径在 v1.0 不实现

> **2026-05-17 amend 触发**：D1 PoC 实测 SIMCOM SIM7600G-H（v1.0 商用 SKU）+ Windows 10/11 上 modem **不注册任何 USB Audio Class endpoint**（`Get-PnpDevice -Class AudioEndpoint` 对该 modem 返回 ∅）。原 Decision 3 假设 "USB Audio Class 路径默认，主流 modem 都走这条" 在主 SKU 上字面错误。AT 通道（COM12）spike 同时确认 SIM7600G-H 走 SIMCom 私有 PCM 协议：**MI_04 接口（在 Windows 上以 `Class=Ports` 形式枚举为 audio COM 端口，本机实测 COM11）+ AT+CPCMREG=1/0 显式启停**。这条 amend 把原 (A) WASAPI 主路径降级为"v1.0 不实现"，新选 (E) SerialPcm 作主路径。原 Decision 3 文本完整保留为否决选项以便 archive 阶段 acceptance.md 引用完整故事。

**选项**：

- (A) sounddevice (PortAudio bindings) + WASAPI ← **PoC 前选定，实测推翻**
- (B) 直接调 Win32 WASAPI API（ctypes / pywin32） ← 排除（同 A，与 USB Audio Class 路径绑定）
- (C) PyAudioWPatch（PyAudio 社区分支，WASAPI loopback 等） ← 排除（同 A）
- (D) PyAudio（原版） ← 排除（同 A）
- (E) SerialPcm-over-COM (MI_04 audio 串口) + AT+CPCMREG 启停 ← **现选定**

**采纳 (E) 的理由**：

- **v1.0 主 SKU 验证一致**：SIMCOM SIM7600G-H 在 Windows 实测**唯一**可行的音频 IO 路径——modem 把 MI_04 作 SIMCom 私有 USB endpoint 而非 USB Audio Class，Windows 枚举为 `Class=Ports`（与 AT / NMEA / Diagnostics 兄弟接口同形态），`sounddevice` / WASAPI / PortAudio **全部列不出**该设备
- **AT 协议标准**：`AT+CPCMREG=1` 启用 PCM 字节流 / `AT+CPCMREG=0` 关闭，spike 实测 SIM7600G-H 固件 `LE20B04SIM7600G22` 上 `AT+CPCMREG=?` 返 `(0-1)`、no-call 状态发 `=1` 返 `ERROR`（确认 per-call lifecycle）；SIMCom 7000/7600/8200 系列均沿用该协议
- **帧契约 modem-fixed**：spike 实测 `AT+CPCMFMT=?` 在 SIM7600G-H 当前固件返 `ERROR`（命令不存在），host 无配置项；按 SIMCom 应用手册 + GSM 物理通道标准统一为 8 kHz / 16-bit / LE / mono；与 `macos_coreaudio.py` / `linux_alsa.py` 既有 backend 的 8 kHz 帧约定**字面一致**（PR #9 的 `WindowsWASAPICapture` 已经按 8 kHz 实装，原 spec 16 kHz 措辞与 PR #9 deviation note 中点出过）
- **依赖面收敛**：删 `sounddevice` / `PortAudio` Windows wheel 依赖（保留 macOS extras 仍用）；Windows extras 减一项；运行时不再依赖 PortAudio 在 Windows 上对 modem PCM 通道的能力假设
- **故障模式更优**：原 WASAPI 路径 `_resolve_device_id()` fallback 到 `sd.default.device` 会**静默指向员工 PC 笔记本麦克风/扬声器**——这是 silent-wrong，没有 error，客户拿到一个"客户端起来了但 AI 听不到"的灾难体验；SerialPcm 路径若 audio 串口找不到 / CPCMREG 失败 / COM 端口被占，**全部硬 fail with HardwareAlert**
- 缺点：与 macOS / Linux backend 不对称（前两者走 sounddevice，Windows 走 pyserial）→ backend abstraction 已用 Protocol（`CaptureBackend.read_chunk()`/`close()`），AudioPipe 不感知；缺点止于"代码风格不同"
- 缺点：CPCMREG=1 必须在 call connected 之后发，比"backend 启动期常驻 stream"多一道编排——见 Decision 8 把这个 lifecycle 交给 orchestrator 而非 backend

**排除 (A)-(D) 的理由**（原 PoC 前理由作为否决记录）：四种 WASAPI 路径都依赖 modem 在 Windows 注册 USB Audio Class endpoint；v1.0 主 SKU SIM7600G-H 字面不满足前提，等价于"backend 启动即失败回退到笔记本默认音频"。如果未来引入显式注册 USB Audio Class 的 modem（社区报告 Huawei E398 / 部分 ZTE MF 系列在 Windows 注册标准 USB Audio Device），可在后续 change 重引入 WASAPI backend 作并列分支，**v1.0 范围不预留接口、不预留环境变量、不预留 dispatch hook**——按 CLAUDE.md "Don't design for hypothetical future requirements" 原则。

**Windows USB GSM modem 音频路径**：

SIM7600G-H 类 SIMCom modem 在 Windows 把 MI_04 audio 接口暴露为**串口 COM 端口**（在 USB composite device 内与 AT/NMEA/Diagnostics 兄弟接口同 `Class=Ports`），其上承载的是 modem 私有 PCM 字节流协议（非 USB Audio Class、非 RNDIS、非 Mass Storage）。host 与 modem 的契约：

```
┌────────────────────────────────────────────────────────────────────┐
│              SerialPcm 通道的 per-call 生命周期                       │
├────────────────────────────────────────────────────────────────────┤
│                                                                    │
│  AT PORT (COM12, MI_02)                                            │
│    │                                                               │
│    ├─ ATD<phone>;                  ─► modem 拨号                    │
│    ├─ <CONNECT URC>                ─► call connected               │
│    ├─ AT+CPCMREG=1                 ─► host 申请 PCM byte stream     │
│    │       │                                                       │
│    │       ▼                                                       │
│  Audio Port (COM11, MI_04, Class=Ports)                            │
│    ╔══════════════════════════════════════════════════════════════╗│
│    ║   serial.Serial("COM11", baudrate=115200, timeout=0.020)    ║│
│    ║   ◄── pcm_in  = ser.read(320)   # 160 samples × 2 bytes      ║│
│    ║                                  # ≈ 20 ms @ 8 kHz int16 LE  ║│
│    ║   ──► ser.write(pcm_out)         # 同帧契约                    ║│
│    ╚══════════════════════════════════════════════════════════════╝│
│    │                                                               │
│    ├─ <NO CARRIER URC> / 本端 ATH ─► call ended                     │
│    └─ AT+CPCMREG=0                  ─► host 释放 PCM byte stream    │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

**PCM 帧约定**（与 A2 audio-bridge 内部环形 buffer 约定一致）：

- 上行 modem mic → audio-bridge：**8 kHz / 16-bit / LE / mono / 20 ms 帧**（modem 物理通道原生，host 不配置）→ audio-bridge 内 `upsample_8k_to_16k` 重采样到 16 kHz
- 下行 audio-bridge → modem speaker：16 kHz / 16-bit / LE / mono / 20 ms 帧 → audio-bridge 内 `downsample_16k_to_8k` 重采样到 8 kHz → 写入 audio COM
- pyserial `serial.read(N)` 在 `timeout` 内阻塞返回最多 N 字节，N = 160 × 2 = 320 时自然产出 20 ms 帧；read 不需 callback、不需 PortAudio 时钟域，与 modem 8 kHz 物理时钟天然同步
- 与 `macos_coreaudio.py` / `linux_alsa.py` 既有 backend 字面相同（同 8 kHz / 同 20 ms / 同 int16 LE / 同 mono）；AudioPipe 上层重采样代码零修改

### Decision 4：进程形态 = 单进程 asyncio + qasync + Windows 启动注册表 Run 项

**进程结构**（单进程，所有逻辑跑在一个 Python event loop）：

```
isales-telephony.exe (PyInstaller frozen)
├── qasync 主循环（融合 Qt event loop + asyncio）
├── pystray tray icon 线程（pystray 自己起 thread，用 queue 与主 loop 通信）
├── asyncio task group：
│   ├── modem_controller task
│   │   ├── USB watcher（pyserial polling）
│   │   ├── AT 命令通道
│   │   └── audio device IO（sounddevice WASAPI）
│   ├── audio-bridge task（ARTC SDK Python wrapper）
│   ├── cloud-edge gRPC client task
│   ├── 本地 SQLite buffer task
│   └── 本地 telephony-api HTTP task（loopback only）
└── PySide6 诊断小窗口（按需 show / hide，不持久占资源）
```

**为什么 qasync**：

- pystray 自己起 daemon thread 跑 tray icon 渲染（pystray on Windows 用 Win32 message loop）→ tray thread 不能阻塞 asyncio event loop
- PySide6 必须在主线程跑 Qt event loop（QApplication）→ Qt loop 与 asyncio loop 二者必须融合，否则两个 loop 都跑不顺
- qasync 用一个 Qt loop 包装 asyncio：`loop = QEventLoop(app); asyncio.set_event_loop(loop)` → asyncio task 在 Qt loop 上 schedule，Qt widget 信号 / 槽与 asyncio task 互通

**Windows 启动注册表 Run 项**：

```
HKCU\Software\Microsoft\Windows\CurrentVersion\Run
  ISales = "C:\Users\<user>\AppData\Local\Programs\isales\isales-telephony.exe"
```

`HKCU`（HKEY_CURRENT_USER）而非 `HKLM`（HKEY_LOCAL_MACHINE）：

- HKCU 不需要管理员权限即可写入 → 员工自助部署友好
- HKCU 是 per-user 启动项 → 多用户共用 PC 时各自独立 token
- 多用户 PC 不是 D1 主战场（员工 PC 通常单用户），但 HKCU 路径无副作用

**安装路径约定**（A2 时点用，D3 接 MSI 后改）：

```
C:\Users\<user>\AppData\Local\Programs\isales\
├── isales-telephony.exe       (PyInstaller frozen)
├── _internal\                  (PyInstaller _MEIPASS 等价，含 Python / DLLs)
├── vendor\
│   └── aliyun-artc-windows\   (ARTC SDK Windows native)
├── icons\
│   └── tray.ico
└── env.example.txt             (空模板)

C:\Users\<user>\AppData\Roaming\isales\
├── env\
│   └── telephony.env           (含 EDGE_DEVICE_TOKEN / CLOUD_GRPC_ENDPOINT)
├── sqlite\
│   └── edge_buffer.db
└── logs\
    └── telephony.log
```

`AppData\Local\Programs` 装程序、`AppData\Roaming` 装用户数据（漫游配置）—— Windows 标准约定。

### Decision 5：激活码注册流程 = 静态 token 最薄一层

A2 阶段 cloud-edge gRPC 鉴权用 `EDGE_DEVICE_TOKEN` 静态字符串（每边缘机一个 token，写在 env）。D1 激活码 = 这个 token 本身：

```
运维（v1.0 单人单租户阶段就是 boss 自己）→
  云端 isales-api 后台「签发边缘 token」按钮 →
  生成一个 64 字符随机字符串 + 在云端登记 →
  分发给员工（微信发字符串 / 写在纸上）

员工 → Windows tray app 首次启动 →
  检测 %APPDATA%\isales\env\telephony.env 不存在 / 无 token →
  弹 PySide6 激活码对话框 →
  员工粘贴 token + cloud endpoint（cloud endpoint 可以预填默认值）→
  写入 telephony.env →
  重启 cloud-edge gRPC client →
  连通后 tray icon 变绿
```

**为什么不引入更复杂的"激活码 → 服务端兑换 token"流程**：

- C2 `multi-tenant-roles-and-leads` 会带完整的 `activation_token` 表 + `seat` 实体 + tenant 关联 + 一次性兑换语义
- D1 在 C2 之前发，临时引入"兑换 endpoint"会双写：现在写一份、C2 推翻重写
- A2 已经定义 cloud-edge bearer token 形态，D1 直接复用，不增加协议复杂度

**未来 C2 接入路径**：D1 的激活码对话框 UX 保留，但底层从"直接写 token 到 env"改为"调云端 `POST /api/activation/redeem` 拿真 token + seat_id + tenant_id"。UX 层零改动。

**激活失败 UX**：

- token 格式错（长度不对 / 含非法字符）→ 对话框红字提示「激活码格式错误」
- token 写入后 gRPC 连不上（云端拒绝）→ tray icon 变红 + 弹窗「激活失败，请检查激活码或联系管理员」 + 重新打开激活码对话框

### Decision 6：tray icon 状态二态（D1 范围）

A2 时点边缘进程状态简化为：

- **绿色**（正常）：cloud-edge gRPC 已连接 + 至少一个 modem `idle` 状态
- **红色**（异常）：cloud-edge 断线 ≥ 30 s 或所有 modem `offline`

三态色（绿 / 黄 / 红）+ 桌面通知 + 详细告警类型由 D2 `hardware-observability` 处理。

**tray 右键菜单（D1）**：

- "打开诊断窗口" → 显示 PySide6 小窗（含：cloud-edge 连接状态、当前 modem 列表 + 状态、最近 10 条 log）
- "重新激活" → 弹激活码对话框（用户激活码失效或换机时用）
- "查看日志" → 在文件资源管理器打开 `%APPDATA%\isales\logs\`
- "退出"

### Decision 7：串口独占访问 = platform-aware shim（POSIX `fcntl.flock` / Windows OS exclusive open）

**问题来源**：A1 `impl-real-at`（archived 2026-05-17）的 `SerialATClient` 在 `at_client.py:24` 顶层 `import fcntl`；`fcntl` 是 Unix-only stdlib，Windows 上 pytest 直接 collect 失败，5 个测试文件（`tests/modem_serial/test_serial_at_client.py` / `tests/test_modem_dial.py` / `tests/test_modem_pump_cancel.py` / `tests/test_fake_modem_e2e.py` / `tests/edge/test_orchestrator.py`）全挂；D1 §9 真硬件验收（含 A1 §3.4 deferred 的 5 通 `SerialATClient` 直接调）必须先解决这一阻塞。

**平台行为差异**（事实层）：

```
平台                                 多进程开同一串口的 OS 默认行为
─────────────────────────────────────────────────────────────────
Linux /dev/ttyUSB*                  允许并发 open；需显式 fcntl.flock 锁
macOS /dev/cu.usbmodem*             允许并发 open；同上
Windows COM* / \\.\COM*             OS 层默认独占（CreateFile 不带
                                    FILE_SHARE_* flag → dwShareMode=0），
                                    第二个 open 直接 PermissionError(13)
```

**选项**：

- (A) 抽 `isales_telephony/modem_controller/platforms/serial_lock.py` 一层（`sys.platform` dispatch；POSIX 走 lazy `import fcntl` + `flock`；Windows no-op handle + open-time `PermissionError` 翻译为 `BusyDeviceError`）← **选定**
- (B) `msvcrt.locking` byte-range lock（Windows stdlib）：`msvcrt.locking` 为 disk file 设计、要求可 seek + nbytes 参数；COM 端口 handle 在这个 API 上的行为未定义，Python 文档未覆盖 → ✗ 拒绝
- (C) `try: import fcntl except ImportError: fcntl = None` + 每处调用点 `if fcntl is not None:` 守卫：`at_client.py` 内 3 处碰 fcntl（顶层 import + `LOCK_EX` + 2 处 `LOCK_UN`），守卫会散到 3 处；与既有 `platforms/get_usb_watcher_class()` 抽象层风格不一致 → ✗ 拒绝

**采纳 (A) 的理由**：

- 与 modem_controller PR #2/#6 已落地的 `platforms/` 抽象层形态对齐——`sys.platform` dispatch + lazy import + 业务代码不感知平台分支（`get_usb_watcher_class()` 是同模式的先例）
- surface area 极小（`acquire_exclusive` + `release` + `BusyDeviceError` 共 3 个 export），函数级抽象就够，不引 ABC
- `BusyDeviceError` 在两个平台都从 `platforms/serial_lock.py` 抛出，调用方对"竞争失败"只有一处错误处理路径
- POSIX 路径行为字面不变（`flock(LOCK_EX | LOCK_NB)` + `BlockingIOError` → `BusyDeviceError`），A1 已落地的 11 个 SerialATClient 单测 + 5 个跨模块测试零回归

**Windows 路径的非显式锁语义**：

`SerialATClient.create_from_tty()` 在 Windows 上的"取独占"动作 = 把 pyserial 的 access-denied 类异常翻译为 `BusyDeviceError`：

```python
# Pseudocode — actual implementation in 3.7+
try:
    reader, writer = await serial_asyncio.open_serial_connection(url=tty_path, ...)
except PermissionError as exc:           # OS-level exclusive open conflict
    raise BusyDeviceError(...) from exc
except SerialException as exc:           # pyserial 包装的 access-denied
    if "Access is denied" in str(exc) or isinstance(exc.__cause__, PermissionError):
        raise BusyDeviceError(...) from exc
    raise RuntimeError(f"failed to open {tty_path}: {exc}") from exc
# OS 已经独占了 → Windows handle = None（platforms.serial_lock 实现层无副作用）
handle = serial_lock.acquire_exclusive(fd=None, tty_path=tty_path)  # returns None on win32
```

POSIX 路径不变：`serial_asyncio.open_serial_connection` 成功 → 拿 fd → `serial_lock.acquire_exclusive(fd, tty_path)` 内部 `flock(LOCK_EX | LOCK_NB)` → 失败抛 `BusyDeviceError`。

**spec delta 形态**：device-hardware spec § "URC → ATEvent 翻译契约" / "串口竞争互斥" Scenario 由 D1 `MODIFIED Requirements` 段全 Requirement 重写（OpenSpec delta 不支持 Scenario-only MODIFIED），新 body 把 fcntl 退到 POSIX-only 子句、补 Windows OS exclusive open 子句、显式约定 `serial_lock.py` 是跨平台抽象单一来源。

### Decision 8：SerialPcm 生命周期 = orchestrator 在 call connected/teardown 时管 CPCMREG；backend 只做 byte stream IO

**问题来源**：Decision 3 amend 后 audio backend 不再是启动期常驻 stream——`AT+CPCMREG=1` 必须在 modem 收到 CONNECT URC 之后发，no-call 状态 modem 返 ERROR（spike 实测）；`AT+CPCMREG=0` 必须在通话结束 / 远端挂断时发，否则 audio COM 端口持续 reserve modem 内部 DSP 资源直至下次重启。这与 PR #9 落地的 `_build_audio_backends()` "启动期构造、跨所有通话复用" 形态不一致。

**选项**：

- (A) backend 持 AT client 引用，暴露 `await open_for_call(call_id) / await close_for_call(call_id)`，内部发 CPCMREG ← 排除
- (B) orchestrator 在 `_CallContext.setup` / `.teardown` 上发 CPCMREG，backend 保持纯 byte stream IO，只暴露 `read_chunk()` / `write_chunk()` / `close()` ← **选定**
- (C) backend 在每次 `read_chunk()` 内 lazy ensure CPCMREG=1 ← 排除（每帧都查 AT 状态太重）

**采纳 (B) 的理由**：

- **关注切面对齐**：AT 命令是 modem-controller 已有的职责（`AtClient` / `SerialATClient` / `ModemDriver` 三层抽象都在 modem-controller 包内）；CPCMREG 是 AT 协议的一部分，归 AT 控制面而非 audio 数据面更顺
- **backend 保持启动期单实例**：`_build_audio_backends()` 不需要改 lifecycle，仍是启动期开 audio COM 端口一次（pyserial `serial.Serial("COM11", ...)`），跨所有通话复用同一 file handle；CPCMREG=1 后 read/write 才有数据流，CPCMREG=0 后 read 阻塞直至下次 =1，pyserial 的 timeout 机制自然 absorb
- **与 [[feedback-check-hardware-first]] 已确认的 EdgeOrchestrator hook 点对齐**：A2 既有 orchestrator 在 call connected/teardown 已经 wire 了 audio-bridge join/leave、jitter buffer 启停——CPCMREG 加进同一 hook 链是单点扩展
- **避免 backend ↔ AT client 双向引用**：backend 持 AT client = 双向依赖 + 测试 mock 翻倍工作量；保持单向"orchestrator 调 backend + orchestrator 调 AT client"

**排除 (A) 的理由**：backend → AT client 反向依赖污染 audio backend 的 Protocol（`CaptureBackend` / `PlaybackBackend` 现 surface 极简——`read_chunk()` / `close()`）；新增 `open_for_call(call_id)` 后 macOS/Linux backend 要 follow 实现 noop，spec 上"backend per-platform 同形态" 的约定打破。

**排除 (C) 的理由**：高频路径（20 ms 一次 read）查 AT 状态机 = 浪费；CPCMREG 也不是 query-only 命令（=1 自身有 side effect）。

**SerialPcm backend 与 orchestrator 协议**：

```
   EdgeOrchestrator._CallContext              SerialPcm{Capture,Playback}
   ──────────────────────────────             ───────────────────────────
   setup(call_id):                            __init__(serial_path, ...):
     # call connected URC 已到                     # 启动期一次性 open
     await at_client.cpcmreg_enable()                serial.Serial("COM11")
     # ↑ 新增。AT+CPCMREG=1 → OK            ◄── read_chunk() 直接拿 PCM
     audio_bridge.join_rtc()                  ── write_chunk() 写下行 PCM
     audio_pipe.start_capture_playback()
                                              # 通话期间 backend handle
                                              # 一直 open，CPCMREG 二态 gate

   teardown(call_id):
     audio_pipe.stop()
     audio_bridge.leave_rtc()
     await at_client.cpcmreg_disable()
     # ↑ 新增。AT+CPCMREG=0 → OK              # 跨通话 backend handle 不关
                                              # 进程退出时才 close()
```

`at_client.cpcmreg_enable / cpcmreg_disable` 是 `AtClient` 上新增的 2 个 helper（薄包装 `send_command("AT+CPCMREG=1")` + 检查 `OK`），与 `AtClient.dial` / `.hangup` 同层。`ModemDriver` 子类可以 override 给非 SIMCom 协议变体（v1.0 不需要）。

**Risk**：v1.0 之外的 modem SKU 可能不支持 CPCMREG（如 Huawei E398 走 USB Audio Class、Quectel EC200 用另一套 AT），等价于该 modem 不属于 v1.0 兼容 SKU。spec 上 SHALL 把 "AT+CPCMREG 支持" 作为 D1 v1.0 modem SKU 准入条件之一，未来扩 SKU 时单开 change 评估。

## Risks / Trade-offs

- **[原 sounddevice WASAPI 实际延迟未实测]** → **已废止**（Decision 3 amend 2026-05-17）。PoC 实测推翻 USB Audio Class 假设，WASAPI 路径退场。
- **[SerialPcm-over-COM 实际延迟未实测]** → impl 阶段第一步（替代原 WASAPI loopback 测试）：写最小脚本（`AT+CPCMREG=1` 后 `pyserial.read(320)` × N 同时 `.write(pcm_silence)` × N，测 modem → 远端 echo → modem 端到端延迟），目标 P95 ≤ 50 ms 与 spec § "音频延迟 SLA" 一致。pyserial 在 Windows 上典型 read 调度延迟 < 5 ms（modem 内部 8 kHz buffer 决定主延迟），预期落在 SLA 内；若超 200 ms 视为 SerialPcm 路径不可用，重新评估 SKU 或 USB driver 版本。
- **[ARTC SDK Windows DLL 与 PyInstaller 打包]** → ARTC SDK Windows native 是一组 `.dll` + Python wrapper；PyInstaller `binaries` 节显式加 DLL，`hidden imports` 加 wrapper 模块；运行时验证 `sys._MEIPASS` 解压目录的 DLL 可加载。如失败，回退到"不 freeze，发 zip + venv 套件"（A2 时点可接受，D3 阶段彻底解决）。
- **[Windows Defender / SmartScreen 拦未签名 exe]** → 已知问题；D3 EV 签名解决；D1 范围给员工 RUNBOOK 教如何右键"允许"或临时关闭 SmartScreen 启发式检查；如客户机器有企业级 AV 拦严，部署受阻 → 这种客户走"装 macOS Mac mini 工程师部署"老路径作为 fallback（已有 impl-deploy-macos 套件）
- **[pystray + qasync + PySide6 三者协作的踩坑]** → 已有社区方案（搜 "pystray qasync PySide6"），但小众；impl 阶段做最小 demo（tray icon + 弹 Qt 窗口 + asyncio task 跑 1000 次 sleep）验证三者能共存 1 小时无 crash；如有阻塞性问题，备选方案 = pystray 不用，改为 Qt6 `QSystemTrayIcon`（PySide6 自带 tray API），但代价是 tray 弹通知能力下降 / 跨平台失去
- **[激活码静态 token 与 C2 动态 token 的兼容性]** → cloud-edge gRPC server（A2 已定）只认 bearer token 字符串，不关心 token 是怎么生成的；D1 静态 token 与 C2 动态 token 在 wire 上无差别；C2 改造无 breaking
- **[Windows USB GSM modem 设备识别策略]** → modem 厂商 VID:PID 列表会随新机型扩展；硬编码列表会过时；impl 阶段策略：先用 VID:PID 白名单匹配 + 失败时所有 COM 端口尝试 `AT` 命令试探（200 ms 超时）；二者结合，VID 表只是加速

## Migration Plan

D1 是**纯新增**，没有 production Windows 客户端要迁移。impl 阶段顺序：

1. **Sprint 0 准备**（与 A2 Sprint 0 共用，参考 A2 design.md Migration Plan）：
   - 准备一台 Windows 10/11 PC + 一根 USB GSM modem 插上确认 COM 端口
   - 装 VS Build Tools（PyInstaller / sounddevice / pywin32 编译依赖）
   - 装 Wireshark + 阿里 RTC 控台 SDK 下载
2. **第一周（PoC 性质）**：
   - 实测 SerialPcm-over-COM 延迟（`AT+CPCMREG=1` + audio COM 端口 read/write loop；原 sounddevice WASAPI loopback 任务因 Decision 3 amend 已废止）
   - 实测 pyserial polling 列举 COM + AT 试探
   - 实测 pystray + qasync + PySide6 三者共存（10 分钟无 crash 即过关）
   - 实测 PyInstaller 打包 + ARTC SDK DLL 加载
   - 上述实测如有 1 项不达标，**触发 design.md 对应 Risk 的备选方案**，本文档对应章节更新
   - **note**：Decision 3 amend 本身就是 PoC week 1 第一条任务的产物——2026-05-17 实测 SIM7600G-H 不注册 USB Audio Class endpoint，触发 design.md Decision 3 + spec § "USB GSM modem 音频设备路径" 反转，详见 amend 注记
3. **第二周（Windows backend 接入既有抽象层）**：
   - `windows_serial.py` + `windows_wasapi.py` 实现，跑 modem-controller 单测
   - audio-bridge 在 Windows 上跑通 ARTC SDK 入会 + PCM 推送（QA 环境）
   - cloud-edge gRPC client 在 Windows 上跑通（与 A2 云端连，A2 此时可能也在 impl 阶段）
4. **第三周（UI + 激活码 + tray）**：
   - `tray.py` / `activation.py` / `main_windows.py` 实现
   - 注册表 Run 项 / AppData 路径约定 / env.example 写入工具
5. **第四周（端到端验证）**：
   - PyInstaller 打包 zip → 解压到一台干净 Windows PC → 跑注册表写入脚本 → 重启 PC → tray 自动起 → 弹激活码 → 输码 → 拨自己手机 → 听 AI 开场白（与 A2 联合 MVP 验收点）
6. **归档准备**：与 A2 同步推进，A2 / D1 任一先 archive 时手工 merge `device-hardware` / `deployment-topology` spec delta

**Rollback**：D1 是纯新增 Windows 路径，"回退"= 不部署 Windows 客户端，继续用 macOS Mac mini（impl-deploy-macos 已 ship）；不存在"Windows 客户端发布后再撤回"的语义（v1.0 尚未对外发布）。

## Open Questions

1. **pystray 在 Windows 11 新 tray UI（隐藏 vs 显示）下的表现**：Win11 默认折叠所有 tray icon 到一个箭头里；用户需要手动"始终显示" → 这影响员工首次体验。impl 阶段写入注册表 `HKCU\Control Panel\NotifyIconSettings\<UID>` 让 icon 默认始终显示？还是接受首次需要用户手动配置？→ 先实测看默认行为
2. ~~**WASAPI Exclusive Mode 是否需要做成可配置**~~ → **已废止**（Decision 3 amend）。WASAPI 路径在 v1.0 不实现，相关 env `ISALES_WASAPI_MODE` 在 amend 后续 task §4.11 一并移除。
3. **PyInstaller onefile vs onedir**：onefile 启动慢但单 exe；onedir 启动快但用户看到 _internal 目录可能误删 → 倾向 onedir + 用户手册说明（D3 MSI 后变成"安装目录"用户无感知）
4. **Windows 多用户 PC**：D1 用 HKCU，每个用户独立 token；如果两用户同时登录 → 两进程同时跑 → 都连云端 → 都拿同一 token？这违反 cloud-edge bearer token "一边缘机一 token" 假设。 → v1.0 文档约定 "员工 PC 单用户使用"，多用户场景拒绝支持，由 C2 seat 模型解决
5. **激活码运维下发流程**：D1 时点云端 isales-api 是否暴露 "签发边缘 token" 按钮？还是 boss 自己跑 Python 脚本生成？→ 倾向 D1 时点用脚本（minimum viable），C1 boss console 时把按钮加进去
