> **2026-05-18 SUPERSEDED — DO NOT MERGE INTO openspec/specs/.** 取代者
> [`macos-artc-pyobjc-binding`](../../../macos-artc-pyobjc-binding/specs/deployment-topology/spec.md)。
> 本 spec delta 保留作思路记录；详见
> [`../../proposal.md`](../../proposal.md) 顶部 SUPERSEDED 块。

## ADDED Requirements

### Requirement: macOS dev-no-modem 部署形态（dev-only，与 Windows 商用 / macOS QA 并列）

iSales 边缘进程 SHALL 在 macOS 上提供第三种部署形态——**dev-no-modem 模式**：单 `isales-telephony-edge` 进程在 mac dev 机上以 `--dev-no-modem` 启动，跳过真 GSM modem 拨号链路，用 mac 系统麦克风 / 扬声器作为 RTC 对端。本形态与既有两种 macOS 形态并列：

- **Windows 商用形态**（v1.0 主形态，由 `arch-cloud-edge-split` + `windows-artc-pybind11` 联合交付，PyInstaller frozen exe + qasync + 真 ARTC + 真 GSM modem）
- **macOS QA / PoC 形态**（A2 既有路径，`impl-deploy-macos` launchd plist + `MacosRtcSession` 同进程 loopback mock）
- **macOS dev-no-modem 形态**（本 Requirement 新增，dev-only，真 mac mic/speaker，无 modem，无真 RTC）

本形态服务于策略层 + 工程层在 mac 上的日常迭代演练，**MUST NOT** 作为 v1.0 MVP 验收路径，**MUST NOT** 进入商用部署，**MUST NOT** 被任何客户机环境使用。

#### Scenario: dev-no-modem 形态的部署边界

- **WHEN** dev 同学需要在 mac 工作机上做策略 / 工程闭环演练
- **THEN** 启动方式 SHALL 是 `pip install -e '.[dev,dev-mac-audio]'` 后跑 `isales-telephony-edge --dev-no-modem --dev-channel <name> --dev-uid <id>`（cloud-side engine 走既有 A2 cloud 部署，可指向 `121.89.85.150` 真 cloud 也可指向 dev 本机起的 engine）
- 进程 SHALL 不需要任何 USB modem / SIM 卡 / 真 ARTC AppId 校验（虽然 cloud-side engine 仍按既有 AppId 配 token 签发，但 mac 端 session 不会真 join RTC 房间）
- 进程 SHALL 单 session 运行，挂断（SIGINT / SIGTERM）后退出

#### Scenario: dev-no-modem 形态与 A2 QA / Windows 商用契约的边界

- **WHEN** v1.0 MVP 验收 / 客户预演 / 任何对外演示
- **THEN** SHALL **NOT** 使用 dev-no-modem 形态；唯一验收路径仍是 Windows 商用形态（Windows frozen exe + 真 ARTC join + 真 GSM modem + 拨真手机 → 听到 AI 开场白）
- dev-no-modem 形态产生的延迟 / barge-in / VAD / TTS 行为 SHALL 作为 dev 调参参考，**MUST NOT** 直接外推为 Windows + 真 RTC + 真 modem 链路的结论

#### Scenario: dev-no-modem 形态与商用 PyInstaller 构建隔离

- **WHEN** 跑 Windows 商用 PyInstaller 构建（`deploy/edge/windows/build.ps1`）
- **THEN** PyInstaller spec **MUST NOT** 收 `sounddevice` / PortAudio / `macos_local_audio_session.py` / dev CLI flag 相关代码路径
- `sounddevice` SHALL 仅在 `isales-telephony` pyproject `[project.optional-dependencies].dev-mac-audio` 中声明；商用构建装 base + Windows-specific extras，不装 dev-mac-audio

#### Scenario: dev recipe 文档位置

- **WHEN** dev 同学查找如何启用 dev-no-modem 形态
- **THEN** 文档 SHALL 位于 `isales-telephony/deploy/edge/macos/dev-recipes.md`（**不**在 `deploy/RUNBOOK-cloud.md` / `deploy/edge/windows/STATE.md` / 任何商用 RUNBOOK 中）
- 文档 SHALL 包含：前置依赖（`brew install portaudio`）/ 强制戴耳机说明 / 一行启动命令 / 选择 input/output device 的方式（`isales-telephony-edge --list-audio-devices`）/ barge-in 演练 step-by-step
