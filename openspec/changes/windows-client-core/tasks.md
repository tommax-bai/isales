## 1. Sprint 0 准备（与 A2 Sprint 0 共用）

- [ ] 1.1 准备 1 台 Windows 10 21H2+ 或 Windows 11 PC + 1 根 USB GSM modem，插上确认 COM 端口枚举
- [ ] 1.2 装 VS Build Tools / Windows SDK（PyInstaller、sounddevice、pywin32 编译依赖）
- [ ] 1.3 装 Wireshark 用于 RTC UDP 抓包
- [ ] 1.4 阿里 ARTC SDK for Windows Python 压缩包从阿里云控台下载，放入与 A2 相同的内部 artifact 仓 / OSS 私有 bucket

## 2. PoC 第一周（实测关键技术风险）

- [ ] 2.1 sounddevice + WASAPI Shared Mode loopback 延迟实测（capture → 立即 playback，测端到端 P50/P95）；目标 ≤ 50 ms
- [ ] 2.2 pyserial polling 在 Windows 上的 COM 端口枚举性能（含 USB VID:PID 读取 + AT 试探超时控制）
- [ ] 2.3 pystray + qasync + PySide6 三者共存最小 demo：tray icon + asyncio sleep loop + 弹 Qt 窗口；目标 10 分钟无 crash
- [ ] 2.4 PyInstaller onedir 打包 + ARTC SDK Windows DLL 加载实测：包大小 / 启动时间 / DLL 加载成功率
- [ ] 2.5 上述任一不达标 → 触发 design.md 对应 Risk 备选方案 + 更新 design.md

## 3. isales-telephony：Windows USB watcher

- [ ] 3.1 新增 `isales_telephony/modem_controller/platforms/windows_serial.py`：USB watcher 用 `serial.tools.list_ports.comports()` 列举 COM + USB VID:PID + AT 试探识别
- [ ] 3.2 新增 `windows_modem_vendors.toml` 配置：USB GSM modem VID:PID 白名单（华为 / 中兴 / SIMCom 主流）
- [ ] 3.3 实现多 COM 端口 modem 识别：AT 试探判定 AT 通道，忽略 PCM / 调试通道
- [ ] 3.4 实现 AT 试探回退（VID:PID 未命中时）+ 试探限频（每 COM 每分钟 1 次）
- [ ] 3.5 实现设备初始化序列（AT+CGMI / CGMM / CGSN / CCID），失败上报 `HardwareAlert{kind="modem_init_failed"}`
- [ ] 3.6 单测：mock pyserial 列举 + AT 响应，覆盖 VID 命中 / AT 试探命中 / 完全无 modem 三种路径

## 4. isales-telephony：Windows 音频 backend

- [ ] 4.1 新增 `isales_telephony/audio_pipe/platforms/windows_wasapi.py`：`WindowsWASAPICapture` / `WindowsWASAPIPlayback` 实现，sounddevice WASAPI Shared Mode 默认
- [ ] 4.2 实现 USB Audio Class 设备识别（sounddevice 列举 + 名称模糊匹配 + 与 modem VID:PID 关联）
- [ ] 4.3 实现帧格式：capture 16 kHz / 16-bit / mono；与 audio-bridge 上行环形 buffer 对接（A2 audio-bridge 内做 8↔16 kHz 重采样）
- [ ] 4.4 实现 buffer-full 反压（sounddevice callback 慢消费 → 暂停 modem 上行读取）
- [ ] 4.5 实现 env `ISALES_WASAPI_MODE=exclusive` 切换 Exclusive Mode
- [ ] 4.6 单测：mock sounddevice，验证 capture / playback stream 开关 / 帧拼接 / 反压

## 5. isales-telephony：tray + 激活码 UX

- [ ] 5.1 新增 `isales_telephony/ui/__init__.py` + `tray.py`：pystray tray icon + 二态色（绿 / 红）+ 右键菜单（打开诊断窗口 / 重新激活 / 查看日志 / 退出）
- [ ] 5.2 新增 `isales_telephony/ui/activation.py`：PySide6 激活码输入对话框（含格式校验 + 错误提示 + 默认 cloud endpoint）
- [ ] 5.3 新增 `isales_telephony/ui/diagnostic.py`：PySide6 诊断小窗（cloud-edge 连接状态、modem 列表、最近 10 条 log）
- [ ] 5.4 实现 tray 与 cloud-edge gRPC client / modem-controller 的状态订阅（asyncio Queue / Qt Signal）
- [ ] 5.5 实现激活码写入 env 文件 → 重启 gRPC client（无需重启进程）
- [ ] 5.6 实现激活失败 UX（gRPC 端验证拒绝 → tray 转红 + 弹通知）

## 6. isales-telephony：Windows entry point + qasync 主循环

- [ ] 6.1 新增 `isales_telephony/main_windows.py`：用 qasync 启动 PySide6 QApplication + 注入 asyncio event loop
- [ ] 6.2 启动序列：检测 env 文件 → 有 token 直接起 task group；无 token 弹激活码对话框；激活成功后再起
- [ ] 6.3 asyncio task group 注册：modem-controller / audio-bridge / cloud-edge gRPC client / 本地 SQLite buffer / 本地 telephony-api HTTP loopback / tray icon
- [ ] 6.4 异常处理：task 异常 SHALL 不阻塞 tray UX；uncaught exception SHALL 写日志 + tray 转红
- [ ] 6.5 优雅退出：tray "退出"菜单 → 取消 task group + LeaveChannel RTC + close gRPC stream + 退出 QApplication

## 7. PyInstaller 打包与部署脚本

- [ ] 7.1 新增 `deploy/edge/windows/isales-telephony.spec`：PyInstaller spec 文件（onedir 模式，含 `binaries` ARTC SDK DLL 与 `datas` 图标）
- [ ] 7.2 新增 `deploy/edge/windows/build.sh` / `build.ps1`：构建脚本（pip 装依赖 + pyinstaller 打包）
- [ ] 7.3 新增 `deploy/edge/windows/install.ps1`：解压 zip + 写注册表 Run 项 + 创建 AppData 目录 + 启动客户端
- [ ] 7.4 新增 `deploy/edge/windows/uninstall.ps1`：移除注册表 Run 项 + 删除程序目录（保留 AppData）
- [ ] 7.5 新增 `deploy/edge/windows/env.example.txt`：env 模板（含 `ISALES_EDGE_DEVICE_TOKEN` / `ISALES_CLOUD_GRPC_ENDPOINT` 等占位）
- [ ] 7.6 准备 tray icon `tray.ico`（设计来源：v1.0 品牌图，128x128）

## 8. pyproject / 依赖隔离

- [ ] 8.1 更新 `isales-telephony/pyproject.toml`：新增 `[project.optional-dependencies]` 节 `windows = ["pystray", "PySide6", "qasync", "sounddevice", "pywin32"]`
- [ ] 8.2 macOS / Linux 安装路径 MUST NOT 拉取 Windows 包（platform marker `; platform_system == "Windows"` 隔离）
- [ ] 8.3 CI 矩阵：增加 Windows runner 跑 Windows-specific unit test（platform-gated）

## 9. 端到端验证（与 A2 联合 MVP）

- [ ] 9.1 干净 Windows PC 上：解压打包 zip → 跑 install.ps1 → tray app 自动起 → 弹激活码对话框 → 输码 → tray 转绿
- [ ] 9.2 插 GSM modem → tray app 检测到 → modem-controller 初始化 + audio device 配对
- [ ] 9.3 端到端：自己手机拨入 → 听到 AI 念固定开场白 → 挂断（与 A2 联合 MVP 验收点）
- [ ] 9.4 故障注入：拔 modem 中途 / 断网 30 s / 重启 PC → 验证降级 + 自动重连
- [ ] 9.5 多用户 PC：测试不同用户登录后 tray 各自起 + 各自 token（v1.0 文档明示"建议单用户"，但验证基础行为不崩）
- [ ] 9.6 Windows Defender 实测：默认 SmartScreen 拦截行为记录 + 临时绕过步骤写入 RUNBOOK（彻底解决在 D3 EV 签名）

## 10. RUNBOOK + 归档准备

- [ ] 10.1 新增 `deploy/edge/windows/README.md`：员工首次部署流程（10 步内）+ 激活码获取方式 + 常见问题（Defender 拦截 / WASAPI 设备选择 / 多 COM 端口识别）
- [ ] 10.2 boss 视角运维：如何签发 EDGE_DEVICE_TOKEN（A2 时点用脚本，C1 引入按钮）
- [ ] 10.3 更新 v1-roadmap.md 标注 D1 已 ship
- [ ] 10.4 A2 / D1 同步推进：归档时手工 merge `device-hardware` / `deployment-topology` spec delta（两 change 内容互不重叠，merge 是拼接而非调和）
- [ ] 10.5 整理 D2 `hardware-observability` propose 阶段需要的上下文（D1 tray 二态色升级到三态 + 健康检测周期任务接入点）
- [ ] 10.6 整理 D3 `windows-installer-and-ota` propose 阶段需要的上下文（D1 PyInstaller onedir → MSI 路径）
