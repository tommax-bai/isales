## Context

iSales 当前已通过 stage 1–7 + impl-modem-controller + impl-deploy 验收，**Linux 单主机**生产部署能力齐备：每个服务 ship `*.service`、meta-repo `deploy/scripts/` 提供 provision / install / deploy / rollback / 备份 / 监控模板 / RUNBOOK。modem-controller 的 udev / ALSA / pyserial 三大子系统已在 isales-telephony stage 6 阶段验收过 Linux 路径。

新增需求：把生产能力扩展到 **macOS 14+ Sonoma on Apple Silicon**，作为门店或现场拨号工作站。Linux 仍是主线，macOS 是新增并行平台。最关键的两块差异在 modem-controller 硬件层（pyudev → IOKit、ALSA → Core Audio）；其余大多数差异是部署 / 服务管理脚本层面。

stakeholders：
- 门店 / 现场场景的部署运维（首次 macOS 上线）
- 开发者（在 Mac 开发机上跑端到端真硬件验证）
- on-call（Linux + macOS 双平台 RUNBOOK 需要平行维护）

7 项关键决策已经定（用户在 propose 阶段拍板）：
1. 真硬件验收必须做（Mac mini / Studio 插 USB GSM modem 跑 3 轮对话）
2. macOS 版本下限 14 (Sonoma)
3. 仅 Apple Silicon
4. impl-deploy 已先归档（前置条件已满足）
5. ABC 一次到位为 Windows 预留位子
6. Core Audio 时延 > 200ms 立即阻塞合并
7. 单 change 内拆 ~12 PR

## Goals / Non-Goals

**Goals:**

- 在一台干净的 Mac mini M2/M4 或 Mac Studio M2 上，按 RUNBOOK macOS 章节的命令序列把 7 个服务全部跑起来并对外可用
- modem-controller 在 macOS 上插入 USB GSM modem 能正确触发 `detected` → `registered` → `idle` 状态机；调用 dial → connected → remote_hangup 完成至少 3 轮真实对话
- Core Audio 端到端时延 ≤ 200ms（下行 PCM 写入到对端 modem 听到）
- 引入 `UsbDeviceWatcher` / `AudioPipe` 双 ABC，业务代码 0 行平台分支
- ABC 类型设计（错误类型、事件 dataclass、命名）允许将来加 Windows 实现而不重构调用方
- Linux 现有 115 测试零回归
- 单 RUNBOOK 容纳两个平台（用 `<details>` 折叠 macOS 节）

**Non-Goals:**

- Windows 实现（本 change 仅为 Win 留 ABC 位子，**不实现** Windows backend）
- Intel Mac 兼容（仅 Apple Silicon）
- macOS 13 / 12 兼容（仅 14+）
- macOS 多主机 / 灰度（与 Linux v1 对齐，单主机起步）
- macOS 容器化部署
- macOS 上 stage 8 hardening 重跑（用本 change 验收过的 macOS 主机另起 hardening change）
- macOS 真硬件性能调优超出 200ms 基线之外的部分（达到 200ms 即可，深度调优另立）
- isales-engine / isales-api / isales-scheduler / isales-worker / isales-web 的代码改动（这些服务 100% 跨平台，业务代码不动）

## Decisions

### Decision 1: 单仓 + 平台抽象层（拒绝三仓 fork）

**选择**：保持现有 7 仓结构，只在 isales-telephony 内引入 `modem_controller/platforms/` 与 `modem_controller/audio/` 两个 ABC 包。

**理由**：
- 业务代码（状态机、IPC handler、AT 命令、event publisher）99% 跨平台；fork 三仓等于把同一份代码维护三次
- 真正与平台耦合的代码集中在 USB 监听 + 音频管道两块，约占 modem-controller 总代码量 < 15%
- ABC 隔离让 CI 矩阵变成 Linux + macOS 双 job 并行，单 PR review 即可覆盖两个平台

**替代方案**：fork 出 `isales-telephony-macos` 仓。被否决：长期维护成本 3x，bug 漂移风险高。

### Decision 2: ABC 一次到位为 Windows 预留

**选择**：ABC 接口设计明确不绑死 Linux + macOS 二元——错误类型 `UsbDeviceWatcherError(platform=…)` 自带平台字段、事件类型用平台中立 dataclass、`__init__.py` 选实现的 dispatch 用枚举表而非 `if/else`。

**理由**：
- 用户 propose 阶段决策 #5：Win 预留位子，多 1–2 天工作量但将来 Win change 心智成本减半
- 不引入 Win backend 实现（YAGNI），但**接口不为 Linux/Mac 二元做特殊优化**

**替代方案**：纯 Mac 优先二元设计。被否决：将来 Win change 立项时 ABC 反复重构，不如一次做对。

### Decision 3: launchd plist 内联展开 env

**选择**：因为 launchd 不支持 `EnvironmentFile=`，`install.sh` 在装配期把 `/etc/isales/env/<service>.env` 文件内容**内联展开**到 plist 的 `<key>EnvironmentVariables</key>` 字典；env 改了要重写 plist + `launchctl bootout && bootstrap` 才能生效。

**理由**：
- launchd 没有 EnvironmentFile 等价物（apple 官方推荐做法就是把 env 写进 plist）
- 内联展开方案保持"集中化 env"的语义不变（运维仍然只编辑 `/etc/isales/env/*.env`），只是部署期多一次同步
- 替代方案"包一层 bash -c source env && exec"会让进程树多一层 bash，影响 ExecStop / 信号传递，不可接受

**替代方案**：每个 plist 写 `<string>/bin/bash -c 'set -a; source /etc/isales/env/X.env; exec /path/to/binary'</string>`。被否决：进程树多一层，launchd KeepAlive / SuccessfulExit 行为不可预测。

### Decision 4: 路径常量保持 `/opt/isales` + `/etc/isales`

**选择**：macOS 上仍用 `/opt/isales/` 与 `/etc/isales/`，与 Linux 完全一致。**不**用 `/Library/iSales/` 或 `~/.isales/`。

**理由**：
- macOS 的 `/opt` 与 `/etc` 是可写的（与 Linux 一致），且不属于 SIP 保护范围
- 减少跨平台路径常量分叉，调用方代码、env 文件、RUNBOOK 命令样例都共享
- 例外：服务管理目录（`/Library/LaunchDaemons/`）与 brew 数据目录（`/opt/homebrew/var/...`）是 macOS 专有，无法共享

**替代方案**：用 `~/Library/Application Support/iSales/`（Apple 推荐的 user-level 路径）。被否决：要求 root 安装的服务用 user 路径不合理；且 macOS LaunchDaemons 跑在 root 下无法访问用户家目录。

### Decision 5: deploy/ 重构为 deploy/{linux,macos,common}/

**选择**：现有 `deploy/scripts/` 改名 `deploy/linux/scripts/`；新增 `deploy/macos/scripts/`；共享 `_lib.sh` 抽到 `deploy/common/_lib.sh`，两个平台都 source。`deploy/scripts/` 保留软链 → `deploy/linux/scripts/` 一个发版周期，向后兼容 RUNBOOK / 外部脚本引用。

**理由**：
- `deploy-check` / RUNBOOK / 主仓 README 现有路径引用都是 `deploy/scripts/`；硬切会破坏运维肌肉记忆
- 软链 deprecation 一个发版周期足够运维更新 cheat sheet
- 将来 Win 接入时 `deploy/windows/` 平行加入即可

**替代方案 A**：所有脚本扁平在 `deploy/scripts/` 但用文件名前缀区分（`linux-provision.sh` / `macos-provision.sh`）。被否决：UI 难看，shellcheck / Makefile target 都要 glob 处理。

**替代方案 B**：硬切，没有兼容软链。被否决：破坏现有 RUNBOOK 中所有命令样例，运维体验差。

### Decision 6: CI 矩阵局限到 isales-telephony

**选择**：仅 isales-telephony 仓的 GitHub Actions 加 `runs-on: macos-14` job 跑 macOS-only 测试集；其他 6 仓维持仅 Linux CI。

**理由**：
- 真正与平台耦合的代码在 isales-telephony；其他仓 100% 跨平台业务逻辑，加 macOS CI 是浪费
- macos-14 GitHub Actions runner 比 ubuntu 慢 ~2x 且配额更紧，限制覆盖面是合理的资源选择

**替代方案**：所有 7 仓双平台 CI。被否决：成本高、收益微（其他仓本就跨平台，跑两次只是重复）。

### Decision 7: 真硬件验收单独里程碑

**选择**：proposal 阶段就把真硬件验收作为 change 关闭的硬条件之一（不是 follow-up）。具体：在 Mac mini M2/M4 或 Mac Studio 上插 USB GSM modem，端到端打通至少 3 轮对话 + Core Audio 时延 ≤ 200ms。

**理由**：
- 决策 #1：必须真硬件
- 决策 #6：时延 > 200ms 立即阻塞
- IOKit USB notification API 与 Core Audio 都有大量文档边界 case，软件层 mock 测试覆盖不到（USB 重连、modem manager 抢占、音频缓冲延迟），必须真机过

**风险**：手头没有 Mac mini 时本 change 卡死。Mitigation：在 PR 顺序里把硬件验收放最后（PR #11 / #12），软件层 PR 可先合并；硬件 PR 单独阻塞 archive。

## Risks / Trade-offs

- [IOKit USB notification API 边界（重连 / 同时插多枚 modem / hub 拓扑变化）] → 真硬件不稳。Mitigation：开发期先在 Mac 上做插拔压测 100 次；真硬件 PR 阶段录制 IOKit 事件日志样本，验收前回放复现；接受首版只支持单 modem，多 modem 留 follow-up。

- [Core Audio 时延高于 ALSA] → 用户感知卡顿。Mitigation：proposal 阶段已决策"超 200ms 立即阻塞"；在 macos_coreaudio.py 实现时用 `sounddevice` 的低延迟模式 + 调小 buffer size；如果 sounddevice 调不下来，回退到直接 PyObjC 调 AudioUnit API（更底层、更可控但工作量翻倍）。

- [AT 串口被 macOS 系统 modem 服务抢占] → 拨号失败。Mitigation：spec 已加 § "macOS 串口被系统抢占" scenario；启动时检测 `lsof /dev/cu.usbmodem*` 并打印诊断；RUNBOOK macOS 章节给"如何禁用系统 modem 服务"步骤（涉及 SIP 关闭 + 内核扩展黑名单）。

- [pyobjc 版本与 macOS 14 兼容] → 编译/运行失败。Mitigation：`pyobjc-framework-IOKit>=10.0` 是 2024 年发版兼容 macOS 14；CI 矩阵 pin macos-14 镜像；如未来 macOS 15+ 引入 IOKit 行为变化，单开兼容性 follow-up。

- [双平台 CI 时长翻倍] → 慢。Mitigation：仅 isales-telephony 加 macOS job；其他仓维持单平台。

- [部署文档维护成本] → RUNBOOK 双写。Mitigation：单 RUNBOOK，用 `<details><summary>macOS</summary>...</details>` 折叠 macOS 节；两个平台命令并列，运维直接选自己平台展开。

- [Linux 现有 deploy/scripts/ 路径破坏] → 运维肌肉记忆失效。Mitigation：软链 `deploy/scripts/` → `deploy/linux/scripts/` 保留至少一个发版周期；deprecation warning 在 `make deploy-check` 输出。

- [真硬件 USB GSM modem 在 macOS 上的 ttyUSB 等价路径不稳] → AT 命令通道偶发断开。Mitigation：每次 `ATClient` 重连尝试用 `pyserial.tools.list_ports.comports()` 重新扫描，不缓存路径；序列化访问加 asyncio Lock（已有，跨平台）。

## Migration Plan

不涉及数据迁移；本 change 是新增平台支持。落地流程：

1. PR #1–#10 软件层：合并到 isales-telephony main + isales-common main + meta-repo main，**Linux 主线零回归**（CI 验证）
2. PR #11 软硬件集成：在一台 Mac mini M2/M4 上插 USB GSM modem 跑端到端 3 轮对话
3. PR #12 验收闭环：归档前在 Mac mini 上完整跑一遍 provision → install → deploy → 真实拨号 → rollback；归档 PR 描述里附演练日志
4. 归档：`/opsx:archive impl-deploy-macos`

回滚策略：本 change 全部是新增（ABC + macOS-only 包 + macOS deploy 子树）；如需回滚，git revert 相关 PR 即可，Linux 路径完全不受影响。

## Open Questions

- 现场 macOS 主机是否需要禁用 Apple 自动更新？v1 RUNBOOK 默认建议禁用（避免 macOS 大版本升级破坏 IOKit / Core Audio 兼容），但具体客户决策。
- 是否在 isales-common 加 `utils/platform.py` 提供统一 platform 检测？目前看 `sys.platform` 直接判断已够，避免过度抽象，倾向**不加**，但若 PR 落地阶段发现 3+ 处重复判断可重新考虑。
- macOS 上 `/var/run/isales/modem.sock` Unix socket 路径是否仍可用？macOS 重启后 `/var/run` 会被清空 + tmpfs，launchd plist 需要在启动前用 `<key>RootDirectory</key>` + `mkdir` hook 创建。已在 design 中假设走 launchd 创建，但具体 plist 字段在 implement PR 阶段需验证。
- isales-web 的 nginx.conf root 路径在 macOS 上是 `/usr/local/var/www/isales-web` 还是 `/opt/homebrew/var/www/isales-web`？brew nginx 默认是后者；install.sh 的 symlink 目标需对应调整。
