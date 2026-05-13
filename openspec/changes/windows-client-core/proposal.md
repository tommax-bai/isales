## Why

A2 `arch-cloud-edge-split` 把架构切成「5 服务上云 + 2 组件留边」，但 A2 假设的边缘机型是 macOS Mac mini——这是 PoC / 内部 QA 形态。**真正的商用形态目标**（[v1-roadmap "边缘交付形态"](../../v1-roadmap.md) L106-140 已敲定）：客户自己的员工，在自家 Windows PC 上装一个客户端，自己插 USB GSM modem，自己输激活码。没有工程师上门、没有专用边缘机硬件成本、客户单方面就能拉起一个 seat。

A2 时点的 Mac mini 形态对**通用化 SaaS 部署**是不够的：

- 工程师上门部署 → 单客户启动成本太高，规模化困难
- macOS 边缘机意味着客户要专门买 Mac mini → 商用层面客户不愿意，且与"员工自带 PC 即可"的目标冲突
- 不在客户自己 PC 上跑，硬件观测 / SIM 卡运维都要远程进 Mac mini

本 change（D1）补 Windows 原生 backend，让 v1.0 边缘形态从"macOS Mac mini 工程师部署"升级为"客户员工的 Windows PC 自助部署"。**D1 与 A2 平行推进**：A2 设计的云-边 gRPC bidi + 阿里 RTC PaaS 媒体面不变，D1 只补足边缘进程在 Windows 平台上的具体实现（音频 backend + USB watcher + 进程托管形态 + 激活码注册 UX）。

**MVP 验收点**（A2 + D1 都落地后）：员工拿一台 Windows PC → 安装客户端（A2 时点暂用脚本部署，MSI 安装包归 D3 `windows-installer-and-ota`）→ 插 GSM modem → 输激活码 → 自己手机打过来 → 听到 AI 开场白 → 挂断。

## What Changes

- **新增 Windows 平台 backend 实现**（不改既有 macOS / Linux backend，遵循 modem_controller / audio_pipe 现有 platform 抽象层）：
  - `isales_telephony/modem_controller/platforms/windows_serial.py`：USB watcher 用 pyserial polling（复用 PR #2 macOS 同款路径，Windows 上 pyserial 原生有效）；端口形态 `COM3` / `COM4` 等（不再是 `/dev/cu.usbserial-*`）；GSM modem 识别用 USB VID:PID + AT 试探
  - `isales_telephony/audio_pipe/platforms/windows_wasapi.py`：`WindowsWASAPICapture` / `WindowsWASAPIPlayback` 实现，通过 `sounddevice`（PortAudio bindings）透明走 WASAPI；MUST 用 WASAPI Exclusive Mode 或 Shared Mode + 低延迟 buffer（≤ 20 ms），不接受 MME / DirectSound 等老 API
- **新增 Windows tray 客户端 UX**：技术栈 PyInstaller（打 frozen exe）+ pystray（tray icon + 通知）+ PySide6（诊断小窗口）+ qasync（融合 Qt 主循环与 asyncio）。**单一 Python 栈**，与既有 isales-telephony 代码零迁移成本（仍是 Python 3.12 异步代码 + ARTC SDK Python wrapper）
- **新增登录即启动**：Windows 启动注册表 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` 写入 isales-telephony 启动项；用户登录后 tray app 自动起，托盘有进程状态（A2 范围：仅二态正常/异常；三态色 + 告警通知归 D2）
- **新增激活码注册流程**：tray app 首次启动检测无 `EDGE_DEVICE_TOKEN` → 弹激活码输入对话框（PySide6 简单窗口）→ 用户粘贴运维下发的激活码（A2 时点是静态字符串）→ 客户端把激活码 + 云端 endpoint 填进本地 env 文件 → 重启 gRPC client 建立云-边长连。**A2 时点激活码 = EDGE_DEVICE_TOKEN 本身**（直接是云端签发的静态 bearer token 字符串）；C2 处理"激活码 → 服务端动态生成 token + seat 绑定 + tenant 关联"的完整体系
- **deployment-topology spec delta**：在 A2 已加的"边缘机部署"基础上，新增 Windows 形态作为与 macOS 并列的 platform option；明确 Windows 进程托管走"注册表 Run 项 + tray app 形态"而非 launchd / systemd
- **device-hardware spec delta**：补完 A2 已占位的"Windows backend 由 D1 提供"——把 pyserial polling 的 Windows 端口约定、WASAPI capture/playback 帧格式、Windows USB 设备识别策略写入 spec
- 引入 dependency（仅边缘 Windows 端）：`pystray`、`PySide6`、`qasync`、`sounddevice`、`pyserial`（已有）、`pywin32`（注册表 + Windows 启动项写入）

**故意不在 D1 范围**：

- MSI 安装包 / EV Authenticode 代码签名 / cx_Freeze 或 WiX 打包（D3 `windows-installer-and-ota`）；D1 阶段用 PyInstaller 输出 zip + 手工解压 + 手工写注册表 Run 项（脚本化）
- OTA 升级器（D3）
- 一键诊断面板 / 三态色告警 / 桌面通知 / 硬件健康检测周期任务（D2 `hardware-observability`）；D1 的 tray icon 仅显示二态（正常 / 异常）
- 多租户 tenant_id schema / 真正的 activation_token 表 / seat 模型（C2 `multi-tenant-roles-and-leads`）；D1 激活码 = 静态 EDGE_DEVICE_TOKEN 字符串，云端不做 token 状态管理
- macOS / Linux backend 改动（既有 A2 + impl-deploy-macos 已 ship，本 change 不动）
- 任何云端代码改动（D1 是纯边缘 change）

## Capabilities

### New Capabilities

无。本 change 不引入新 capability spec——所有变更都体现在既有 spec 的 delta 上（`device-hardware` / `deployment-topology` 两份），符合 feedback "不要凭空提新增机制"。

### Modified Capabilities

- `device-hardware`: 在 A2 已加的「audio-bridge 组件」「边缘进程结构」基础上，补完 Windows 平台特定要求——pyserial polling USB watcher 的 Windows 端口策略、`WindowsWASAPICapture/Playback` 帧格式与延迟约束、Windows USB GSM modem 识别策略（VID:PID + AT 试探）。
- `deployment-topology`: 在 A2 已加的「边缘机部署」基础上，新增 Windows 形态作为 platform option 与 macOS 并列；新增 Windows 进程托管方式（注册表 Run 项 + tray app 单进程异步）；新增 Windows 安装路径约定（A2 时点手工解压目录，D3 接 MSI 后改）。

## Impact

**仓库与代码影响**（仅 isales-telephony 仓库，仅边缘 Windows 端，不动云端）：

| 文件 / 目录 | 改动 |
|---|---|
| `isales_telephony/modem_controller/platforms/windows_serial.py` | 新增。USB watcher（pyserial polling 列举 COM 端口 + USB VID:PID + AT 试探识别 GSM modem）；接口与 macOS 平台 backend 同形（duck typing 或共享 ABC）。 |
| `isales_telephony/audio_pipe/platforms/windows_wasapi.py` | 新增。`WindowsWASAPICapture` / `WindowsWASAPIPlayback` 实现，sounddevice 透明走 WASAPI；exclusive / shared mode 由 env 控制（默认 shared 兼容性更好，exclusive 仅在低延迟需求强场景启用）。 |
| `isales_telephony/ui/tray.py` | 新增。pystray 托盘 + PySide6 诊断小窗口 + qasync 主循环；状态二态（正常 / 异常） |
| `isales_telephony/ui/activation.py` | 新增。激活码输入对话框（PySide6）；用户粘贴激活码 → 写入 `%APPDATA%\isales\env\telephony.env` 的 `ISALES_EDGE_DEVICE_TOKEN` 字段 → 提示重启 / 自动重启 gRPC client |
| `isales_telephony/main_windows.py` | 新增。Windows 平台 entry point，用 qasync 启动 PySide6 主循环并把 asyncio task group（modem-controller / audio-bridge / cloud-edge gRPC client / 本地 telephony-api）挂到 event loop |
| `isales_telephony/main_macos.py` | 重命名或保留既有 entry point；docstring 标注 macOS 走 launchd 路径，Windows 走 `main_windows.py` |
| `deploy/edge/windows/` | 新增目录：PyInstaller spec 文件、注册表 Run 项写入脚本（pywin32）、env.example、tray icon 资源（一张 .ico）、激活码 README |
| `pyproject.toml` / `requirements-windows.txt` | 新增 Windows extra：`pystray`、`PySide6`、`qasync`、`sounddevice`、`pywin32`；macOS / Linux extra 不变 |

**测试影响**：

- Windows 平台 unit test：需要在 Windows runner（CI 或本地 Windows 机）跑；macOS / Linux 不强求 Windows backend 测试通过（platform-gated）
- 集成测试：QA 阶段需要一台真 Windows 机 + 真 GSM modem，无法在 CI 完成

**外部资源**：

- 无新增外部 SaaS 依赖（继续用 A2 已开通的阿里云 + RTC AppId）
- 边缘 Windows PC 系统要求：Windows 10 21H2+ 或 Windows 11，python 3.12 运行时（PyInstaller 包内打包，无需用户单独装 Python）

**变更链接**：

- 并行：A2 `arch-cloud-edge-split`（云-边架构 + 云-边 gRPC + 阿里 RTC + audio-bridge / modem-controller 边缘进程结构）；D1 与 A2 共享 `device-hardware` / `deployment-topology` 两份 spec delta
- 上游：impl-real-at（已归档）、impl-deploy-macos（已归档）— 既有 macOS backend 与 modem_controller / audio_pipe 抽象层是 D1 复用的基础
- 下游：D2 `hardware-observability`（健康检测 + 三态色 + 一键诊断）；D3 `windows-installer-and-ota`（MSI + EV 签名 + OTA）；C2 `multi-tenant-roles-and-leads`（动态激活码 + seat schema）

**与 A2 的 spec delta 冲突**：

- 两个 change 都在 `device-hardware` / `deployment-topology` 上写 spec delta，OpenSpec archive 时会触发冲突需手工 merge。
- 冲突处理策略：A2 与 D1 在两个 spec 中的写法**互不重叠 / 互相补充**——A2 写云-边架构 / macOS 边缘 / audio-bridge 组件 / modem-controller 角色；D1 在 A2 之后再补 Windows platform-specific 细节（spec delta 中标注 "依赖 A2 已落地的 audio-bridge 组件"）。两个 change 谁先 archive 都不影响另一个的实施，只在 archive merge spec 时把两份 delta 串起来。

**Risk & 缓解**：

| 风险 | 缓解 |
|---|---|
| sounddevice / PortAudio 在 Windows 上 WASAPI 低延迟实测延迟未知 | impl 阶段最小脚本实测（loopback 录音 → 重放，测端到端延迟）；如延迟 P95 > 50 ms，design.md 接受"WASAPI exclusive mode + 减小 buffer" 或"换 PyAudioWPatch 提供的现代 WASAPI bindings" |
| PyInstaller 打包后 ARTC SDK 二进制（.dll）找不到 | impl 阶段把 ARTC SDK Windows native binary 显式加进 PyInstaller `binaries` / `datas` spec；运行时 `sys._MEIPASS` 解压目录注入 PATH |
| 用户输错激活码或激活码失效 | tray 显示"激活失败"状态 + 弹窗让用户重输；A2 静态 token 形态下"失效"的可能性极小（运维给错 token / token 被云端吊销） |
| Windows Defender / SmartScreen 拦未签名 exe | D1 阶段允许这个问题（用户右键允许或本地脚本部署）；D3 引入 EV 签名彻底解决；D1 范围内 RUNBOOK 说明绕过步骤 |
| pyserial polling 在 Windows COM 端口扫描频率高时 CPU 占用 | 复用 macOS 已验证的轮询间隔（典型 1-2 s），Windows 上预期同量级；如实测 CPU 高，加入 USB 设备变更通知（Windows `WM_DEVICECHANGE` 消息）做触发式探测 |
| PySide6 + qasync 主循环异常导致 tray 卡死 | qasync 已经成熟（社区 5+ 年），低风险；impl 阶段把 task group 异常隔离 + uncaught exception handler 上报；最坏退化为 tray 卡死但 modem-controller / audio-bridge asyncio task 仍在跑 |
