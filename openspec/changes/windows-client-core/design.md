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

### Decision 3：音频 backend = sounddevice 透明走 WASAPI，PCM 帧 16 kHz / 16-bit / mono / 20 ms 框架

**选项**：

- (A) sounddevice (PortAudio bindings) + WASAPI ← **选定**
- (B) 直接调 Win32 WASAPI API（ctypes / pywin32）
- (C) PyAudioWPatch（PyAudio 维护断档后的社区分支，加入 WASAPI loopback 等现代特性）
- (D) PyAudio（原版）

**采纳 (A) 的理由**：

- **跨平台抽象一致**：sounddevice 是 PortAudio Python bindings，PortAudio 在 Windows 上自动走 WASAPI（默认）/ MME / DirectSound，业务代码不感知；与 macOS 既有 sounddevice 用法对称
- **延迟可控**：PortAudio + WASAPI Shared Mode 典型延迟 10-30 ms；Exclusive Mode 可压到 5-10 ms（独占设备，其他程序静音）。D1 默认 Shared Mode（兼容性更好，员工 PC 同时跑微信 / 浏览器不被静音）
- **API 简单**：`sd.InputStream(samplerate=16000, channels=1, dtype='int16', callback=...)` 直接 callback 拿 PCM
- 缺点：sounddevice 单进程内同设备并发开 stream 有时崩 → 强制单进程内一个 modem 只开一对 capture / playback stream

**排除 (B) 的理由**：自己写 ctypes 调 WASAPI 一千行代码 + 易踩 COM apartment / threading 坑；sounddevice 已经解决。

**排除 (C/D) 的理由**：PyAudio 老 API、维护断档；PyAudioWPatch 不如 sounddevice 标准、社区小。

**Windows USB GSM modem 音频路径**：

部分 USB GSM modem 在 Windows 把音频通道暴露为标准 USB Audio Class（系统设备管理器里能看到"USB Audio Device"输入输出对）；部分老 modem 把音频走串口 PCM 数据帧（与 AT 通道复用 COM 端口）。D1 SHALL 同时支持两种：

- **USB Audio Class 路径**（默认，主流 modem 都走这条）：通过 sounddevice 选 modem 在 Windows 注册的音频设备 → WASAPI 拿 PCM；设备识别用 sounddevice 列举 + 名称模糊匹配（如包含 "Mobile" / "GSM" / VID:PID 关联）
- **串口 PCM 路径**（兜底，给老 modem 用）：通过 pyserial 从 AT 通道之外的另一个 COM 端口取 PCM；A2 时点不强求实现，留给 D2 / D3 阶段补

**PCM 帧约定**（与 A2 audio-bridge 内部环形 buffer 约定一致）：

- 上行 modem mic → audio-bridge：8 kHz / 16-bit / mono / 20 ms 帧（modem 原生）→ audio-bridge 重采样到 16 kHz
- 下行 audio-bridge → modem speaker：16 kHz / 16-bit / mono / 20 ms 帧 → audio-bridge 重采样到 8 kHz
- WASAPI capture / playback callback 帧长由 PortAudio 内部决定（典型 10-20 ms），audio-bridge 内做 chunk 拼接

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

## Risks / Trade-offs

- **[sounddevice WASAPI 实际延迟未实测]** → impl 阶段第一步：写最小脚本（capture → 立即 playback loopback）测端到端延迟。如 P95 > 50 ms，design Decision 3 接受切到 WASAPI Exclusive Mode 或换 PyAudioWPatch；如 > 200 ms 视为 backend 不可用，重新评估。
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
   - 实测 sounddevice WASAPI loopback 延迟
   - 实测 pyserial polling 列举 COM + AT 试探
   - 实测 pystray + qasync + PySide6 三者共存（10 分钟无 crash 即过关）
   - 实测 PyInstaller 打包 + ARTC SDK DLL 加载
   - 上述实测如有 1 项不达标，**触发 design.md 对应 Risk 的备选方案**，本文档对应章节更新
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
2. **WASAPI Exclusive Mode 是否需要做成可配置**：Exclusive Mode 延迟低但独占设备（员工 PC 同时跑微信会议等会被静音）。默认 Shared Mode 保兼容性 + 提供 env `ISALES_WASAPI_MODE=exclusive` 切到独占？→ 倾向是，但 D1 先实现 Shared Mode、Exclusive Mode 留 D2 / D3 调优时再加
3. **PyInstaller onefile vs onedir**：onefile 启动慢但单 exe；onedir 启动快但用户看到 _internal 目录可能误删 → 倾向 onedir + 用户手册说明（D3 MSI 后变成"安装目录"用户无感知）
4. **Windows 多用户 PC**：D1 用 HKCU，每个用户独立 token；如果两用户同时登录 → 两进程同时跑 → 都连云端 → 都拿同一 token？这违反 cloud-edge bearer token "一边缘机一 token" 假设。 → v1.0 文档约定 "员工 PC 单用户使用"，多用户场景拒绝支持，由 C2 seat 模型解决
5. **激活码运维下发流程**：D1 时点云端 isales-api 是否暴露 "签发边缘 token" 按钮？还是 boss 自己跑 Python 脚本生成？→ 倾向 D1 时点用脚本（minimum viable），C1 boss console 时把按钮加进去
