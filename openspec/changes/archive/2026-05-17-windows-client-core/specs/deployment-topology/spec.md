## ADDED Requirements

### Requirement: Windows 边缘形态

v1.0 边缘机 platform option SHALL 包括 Windows 10 21H2+ / Windows 11（x64），作为商用主形态；macOS Mac mini 形态保留为 PoC / 内部 QA 场景。Windows 边缘进程 SHALL 以单 PyInstaller frozen exe + asyncio + Qt 主循环（qasync）形态运行，通过 Windows 启动注册表 Run 项实现"登录即启 tray app"。

本 Requirement 补充 A2 `arch-cloud-edge-split` 中「边缘机部署」要求，把 Windows 与 macOS 作为并列 platform option 落地。

#### Scenario: Windows 系统要求

- **WHEN** v1.0 客户员工部署边缘客户端
- **THEN** PC SHALL 满足：
  - Windows 10 21H2 或更新（x64）/ Windows 11（x64）
  - 至少 4 GB RAM / 200 MB 可用磁盘（含 PyInstaller frozen 包 + ARTC SDK DLL）
  - 至少 1 个可用 USB 端口（接 GSM modem）
  - 网络可访问云端 gRPC TLS endpoint + 阿里 RTC UDP 端口
  - **不要求** Python 运行时已安装（PyInstaller 包自带）
  - **不要求** 管理员权限（注册表写 HKCU，AppData 写 user 目录）
  - **不支持** Windows ARM64 / Windows Server / Windows 10 LTSC（v1.0 范围外）

#### Scenario: Windows 安装路径约定

- **WHEN** 部署 Windows 客户端（A2 时点：手工解压 + 脚本写注册表；D3 后用 MSI 安装包）
- **THEN** 文件 SHALL 落在以下位置：
  ```
  C:\Users\<user>\AppData\Local\Programs\isales\
    isales-telephony.exe        # PyInstaller frozen 主程序
    _internal\                  # PyInstaller _MEIPASS 等价（Python 运行时 + 依赖）
    vendor\
      aliyun-artc-windows\     # ARTC SDK Windows native binary（.dll）+ 项目内 pybind11 binding
    icons\
      tray.ico
    env.example.txt             # 空 env 模板

  C:\Users\<user>\AppData\Roaming\isales\
    env\
      telephony.env             # 用户 token + cloud endpoint 配置（含 EDGE_DEVICE_TOKEN）
    sqlite\
      edge_buffer.db            # 离线事件 buffer（A2 已定义）
    logs\
      telephony.log
  ```
- `AppData\Local\Programs` 装程序、`AppData\Roaming` 装用户配置，符合 Windows 标准约定；MUST NOT 把可写文件（env / sqlite / log）混到 `Local\Programs` 目录（与未来 D3 MSI 安装目录权限模型冲突）

#### Scenario: Windows 进程托管（启动注册表 Run 项）

- **WHEN** Windows 客户端部署
- **THEN** SHALL 写入 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`，名为 `ISales`，值指向 `isales-telephony.exe` 完整路径；MUST 使用 HKCU 而非 HKLM（不需要管理员权限 + 多用户 PC 各自独立配置）；用户登录后 tray app SHALL 自动启动；MUST NOT 引入 Windows Service 形态（v1.0 范围；服务化形态如有需要由 D3 评估）

#### Scenario: 单进程异步架构

- **WHEN** Windows 客户端运行
- **THEN** isales-telephony SHALL 以**单一进程** + qasync（融合 Qt event loop 与 asyncio）形态运行；进程内 asyncio task group 含：modem-controller / audio-bridge / cloud-edge gRPC client / 本地 SQLite buffer / 本地 telephony-api HTTP loopback；进程内 Qt 端含：pystray tray icon（daemon thread）/ PySide6 诊断小窗 / PySide6 激活码对话框；**MUST NOT** 拆为多进程或引入 IPC（同一进程内 asyncio Queue 即可）

#### Scenario: Tray UX 二态

- **WHEN** Windows 客户端运行
- **THEN** tray icon SHALL 展现二态：
  - **绿色**：cloud-edge gRPC 已连接 + 至少一个 modem 处于 `idle` 状态
  - **红色**：cloud-edge 断线 ≥ 30 s 或所有 modem `offline`
- D1 范围 MUST NOT 引入三态色 / 桌面通知 / 详细告警类型（这些归 D2 `hardware-observability`）；右键菜单 SHALL 至少含 "打开诊断窗口" / "重新激活" / "查看日志" / "退出" 四项

#### Scenario: 激活码注册流程

- **WHEN** Windows 客户端首次启动且检测到 `%APPDATA%\isales\env\telephony.env` 不存在或缺少 `ISALES_EDGE_DEVICE_TOKEN`
- **THEN** SHALL 弹出 PySide6 激活码对话框，要求用户粘贴激活码（A2 阶段激活码 = 云端签发的静态 EDGE_DEVICE_TOKEN 字符串）+ 可选的 cloud endpoint（含合理默认值）；用户提交后 SHALL：
  1. 校验激活码格式（非空 / 长度合理 / 字符集）
  2. 写入 `%APPDATA%\isales\env\telephony.env`（含 `ISALES_EDGE_DEVICE_TOKEN` 与 `ISALES_CLOUD_GRPC_ENDPOINT`），文件权限交由 Windows ACL 默认（user-owned）
  3. 重启 cloud-edge gRPC client task（无需重启整个进程）
  4. 连接成功 SHALL 关闭对话框 + tray icon 转绿；连接失败 SHALL 在对话框显示错误 + 允许用户重输

#### Scenario: 激活码失效与重新激活

- **WHEN** 已激活的客户端 gRPC server 端验证失败（如 token 在云端被吊销 / 边缘机被换 token）
- **THEN** tray icon SHALL 转红 + 弹通知 "激活失败，请检查激活码"；右键菜单 "重新激活" SHALL 弹出激活码对话框，允许覆盖现有 token；MUST NOT 在 token 无效时静默重试（避免误导用户）

#### Scenario: macOS 边缘形态保留

- **WHEN** v1.0 部署
- **THEN** macOS Mac mini 形态（由 `impl-deploy-macos` 已 ship 的 launchd plist 部署套件）SHALL 继续作为支持选项，主要用于：(a) iSales 内部 QA / PoC 环境（A2 主形态）/ (b) 个别企业客户机房集中部署需求；商用主推 Windows，但 macOS 路径 MUST NOT 被本 change 移除

### Requirement: Windows 客户端依赖与打包

Windows 客户端 SHALL 通过 PyInstaller 打包为可移植目录（onedir），含 Python 运行时 + 所有 PyPI 依赖 + ARTC SDK Windows native binary；最终产物 SHALL 在干净的 Windows 10 21H2+ / Windows 11 PC 上解压即可运行（无需用户单独装 Python 或 VC 运行时）。

#### Scenario: Windows-specific 依赖

- **WHEN** 边缘 Windows 客户端打包
- **THEN** 依赖 SHALL 至少包含：
  - `pystray`（tray icon）
  - `PySide6`（Qt UI，LGPL 商用友好）
  - `qasync`（Qt + asyncio 融合）
  - `sounddevice`（PortAudio Python bindings → WASAPI）
  - `pyserial`（COM 端口枚举与 IO，已是既有依赖）
  - `pywin32`（注册表 + Windows 启动项写入）
  - `grpcio` / `grpcio-tools` / `protobuf`（与 A2 cloud-edge gRPC client 一致）
  - 阿里 ARTC SDK for Windows native binary（vendor）+ 项目内 pybind11 binding（`aliyun_artc_pywrap.pyd`，由 build.ps1 CMake 阶段产出，详见 `openspec/changes/windows-artc-pybind11/`）
- macOS / Linux 平台 MUST NOT 强制安装上述 Windows-specific 包（通过 pyproject `extras` 或 platform marker 隔离）

#### Scenario: PyInstaller 打包配置

- **WHEN** 执行 `deploy/edge/windows/build.sh` 或等价构建脚本
- **THEN** PyInstaller SHALL：
  - 模式：`onedir`（不用 `onefile`，避免每次启动解压 200-500 ms 延迟 + AV 误报）
  - 入口：`isales_telephony/main_windows.py`
  - 显式包含 ARTC SDK Windows native `.dll` 文件（`binaries` 节）
  - 显式包含 tray icon `.ico` 资源（`datas` 节）
  - 隐藏导入：`aliyun_artc_pywrap`（项目内 pybind11 模块名，详见 `openspec/changes/windows-artc-pybind11/`）、`PySide6.QtCore` 等运行时 import 模块
  - 输出目录：`dist/isales-telephony/`（`isales-telephony.exe` + `_internal/`）
  - 不强求代码签名（D3 处理 EV Authenticode）

#### Scenario: 部署脚本

- **WHEN** 用户首次部署 Windows 客户端
- **THEN** `deploy/edge/windows/install.ps1`（PowerShell 脚本）SHALL：
  1. 解压发布 zip 到 `%LOCALAPPDATA%\Programs\isales\`
  2. 写入 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` 启动项
  3. 创建 `%APPDATA%\isales\{env,sqlite,logs}\` 目录
  4. **不**写入 env 文件中的 token（由 tray app 首次启动的激活码对话框完成）
  5. 启动 `isales-telephony.exe`
- 卸载脚本 `deploy/edge/windows/uninstall.ps1`：删除注册表 Run 项 + 删除 `%LOCALAPPDATA%\Programs\isales\` + 保留 `%APPDATA%\isales\` 以备重装（卸载彻底清理留给 D3）

#### Scenario: 网络要求（与 A2 一致）

- **WHEN** Windows 边缘机部署
- **THEN** SHALL 能出向访问：
  - 云端 cloud-edge gRPC TLS endpoint
  - 阿里 RTC PaaS 媒体面（动态 UDP 端口段，备用 TCP）
  - OSS endpoint（远程诊断包上传 / 开场白预渲染下载占位）
- MUST NOT 监听任何公网端口；本地 telephony-api MAY 监听 `127.0.0.1` 任一端口仅供本机查询；Windows 防火墙规则 MAY 由 install.ps1 自动配置出向规则
