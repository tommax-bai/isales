## Why

iSales v1.0 端到端拨号链路 (`scheduler 取数 → engine 接 ARTC →
edge 接同房间 → 音频流通 → AI 念开场白 → 挂断 → call_record + transcript
落库`) **从未跑通过一次完整闭环**。所有零件都在仓里:

- cloud-edge gRPC 控制面 ✓ (`arch-cloud-edge-split` 已 archive，2026-05-17
  smoke 验证 `==> CONNECTED / Heartbeat OK`)
- AT 实装 ✓ (`impl-real-at` 2026-05-17 archive)
- modem-controller ✓ (`impl-modem-controller` 2026-05-09 archive)
- Windows edge client framework ✓ (`windows-client-core` 2026-05-17
  archive — `main_windows.py` + tray + qasync + activation dialog)
- ARTC Python pybind binding ✓ (`windows-artc-pybind11` §9.1 / §9.2
  ticked — `aliyun_artc_pywrap.cp312-win_amd64.pyd` import 通)
- provider 凭据 DB SSOT ✓ (`impl-provider-credential-db-ssot` 2026-05-24
  archive — engine 启动期 `credentials_loaded count=2`)

但 **没有任何一个 session 把所有零件串起来跑通过端到端拨号**。
`isales-telephony/deploy/edge/windows/STATE.md § "What's NOT yet done"`
明列:

- pybind §9.4 真 RTC join (缺 RTC client token signed with AppKey + 实测
  `on_join_channel_result(code=0)` 回调)
- pybind §9.5 真 PCM push/pull P95 ≤ 50 ms
- edge full daemon 在本机真启动 (`main_windows.py` 入口写了但没串通
  COM12 AT + COM11 SerialPcm + .pyd + gRPC + token 一锅烩)

A2 §12.2 也明列「接入豆包 ASR/LLM/TTS：拨自己手机 → 听到 AI 念固定开
场白 → 挂断 ← **A2 + D1 联合 MVP 验收点**」未做。

本 change 把"最后一公里"凑齐，**用 dev 自己的手机号 13301035545 拨通一
次完整电话听 AI 开场白**，作为整个 iSales 平台从代码到商业价值的**首次
端到端商业验证**。

## What Changes

- **NEW**: `isales-telephony/scripts/pybind_rtc_join_smoke.py` —
  Windows 上用 `aliyun_artc_pywrap.EngineHandle` + RTC client token (向
  ECS engine 申请) 真 join 测试房间，验 `on_join_channel_result(code=0)`
  事件。对应 pybind §9.4。
- **NEW**: `isales-telephony/scripts/pybind_pcm_loopback_smoke.py` —
  edge push silence PCM → 同房间 ECS engine pull 到，反向同步，端到端
  延迟测量 (P95 ≤ 50 ms gate)。对应 pybind §9.5。
- **NEW**: `isales-engine` CLI `isales-engine-mint-rtc-token` — 用既有
  `RtcTokenIssuer.sign(channel, user_id)` 包装；输出 JSON 含 token +
  app_id + nonce + expires_at；smoke 脚本 ssh ECS 跑 CLI 拿 token，
  AppKey 不离 ECS。**生产 dial 流程已经在 `DialCommand.rtc_token` 字段
  下发 token (proto 现状)，本 CLI 仅服务 §9.4 / §9.5 等离线 smoke 场景。**
- **MODIFIED**: `isales-telephony/isales_telephony/main_windows.py` —
  端到端串通 COM12 AT + COM11 SerialPcm + ARTC pybind + cloud-edge gRPC
  client + 加载 `.edge-token-test.jwt`；解决既有"框架就位但没真启动"状态。
- **NEW**: `isales-telephony/scripts/joint_mvp_dial.py` — 一键拨号脚本
  CLI (`--phone 13301035545 --campaign-id N [--dry-run]`)：① 启 edge
  daemon 并等连云；② trigger scheduler push DialRequest；③ 监听
  call_record.status 状态机；④ 验证 transcript 含 AI 开场白文本；⑤
  挂断或超时 (默认 60s)。
- **NEW**: PG seed: 1 campaign (name "MVP test" / concurrency=1 / 单
  时段 / 1 个简单 role prompt "您好，这里是 iSales 测试") + 1 lead
  (phone=13301035545 / status=new)。`isales-common/cli/` 加 seed CLI
  或直接 psql 一行。
- **NEW**: `deploy/cloud/STATE.md` + `isales-telephony/deploy/edge/windows/STATE.md`
  加 MVP gate 通过证据 (call_record id + transcript[0] 文本 + duration
  + 是否听到 AI 开场白 yes/no)。
- **MODIFIED**: `device-hardware` spec § "device 状态机" 加一个 Scenario
  覆盖 "edge daemon 真启动后 COM12/COM11 双通道实测可达"；本 change 是
  该 Scenario 的首次落地证据。
- **MODIFIED**: `deployment-topology` spec § "cloud-edge 拓扑" 加一个
  Scenario 覆盖 "edge full daemon up + ARTC RTC join + 真号拨通"；本
  change 是该 Scenario 的首次落地证据。

## Capabilities

### New Capabilities

<!-- 无新 capability。拨通本身是 ai-pipeline + call-state-machine +
     device-hardware + deployment-topology + provider-abc 等多个已 spec'd
     能力的端到端验收，本 change 不引入新行为。 -->

### Modified Capabilities

- `device-hardware`: 加一个 Scenario 验 "edge daemon 真启动 + COM12 AT
  + COM11 SerialPcm 双通道实测"，把 §1.2 拨打期间收到 AT 命令的 spec
  从 "spec'd but 单元测试" 升级到 "端到端实测通过"。
- `deployment-topology`: 加一个 Scenario 验 "cloud-edge full daemon up
  + ARTC RTC join + 真号拨通"，把现有的 cloud-edge topology spec 从
  "smoke 仅 gRPC heartbeat" 升级到 "完整音频通路实测"。

## Impact

- **affected repos**:
  - `isales-telephony` (重):
    - `scripts/pybind_rtc_join_smoke.py` (新, §9.4)
    - `scripts/pybind_pcm_loopback_smoke.py` (新, §9.5)
    - `scripts/joint_mvp_dial.py` (新, 端到端 CLI)
    - `isales_telephony/main_windows.py` (modified, 串通五件套)
    - `deploy/edge/windows/STATE.md` (updated, MVP gate 证据)
  - `isales-api` (轻): 加 `mint_rtc_token` 路径 (CLI 或
    `/api/edge-devices/{id}/rtc-token` endpoint — 设计中决定)。
  - `isales-engine`: 可能需补「engine 加入测试 RTC 房间 + 监听 channel
    join 事件」的入口 — 已有 RtcTelephonyClient 框架但拨号链路里实际
    join 路径需走通。
  - `isales-common`: 可能加 `isales-seed-mvp` CLI (1 campaign + 1 lead)
    或直接走 psql。设计中决定。
  - `deploy/cloud/STATE.md` (updated): 加 MVP gate 通过证据块。
- **affected specs**: `device-hardware` + `deployment-topology` 各
  +1 Scenario。
- **依赖** (must be true before apply):
  - Windows dev box 在 `C:\Users\tianx\codes\isales-telephony` 有
    SIM7600G-H modem 连接 (COM12 AT + COM11 audio active；信号满格)
  - ECS `121.89.85.150` 4 服务 active + alembic head b2c3d4e5f6a7
  - `ISALES_RTC_APP_KEY` 已在 ECS engine.env (`o6dpsan9` AppId +
    `c4f5feb...` AppKey)
  - DB 含 volcengine 凭据 (`provider_credential` 表 2 行)
  - `.edge-token-test.jwt` 已 mint (per deploy/cloud/STATE.md §
    EDGE_DEVICE_TOKEN，TTL 365d)
- **BREAKING**: 无。所有改动是新增功能 / 实测脚本 + 文档；不改 spec
  现有 Requirement 的"必须"子句。
- **out-of-scope**:
  - A2 §12.3 latency P50/P95 测量 → 另开 change
  - A2 §12.4 故障注入 → 另开 change
  - A2 §12.5 100 seats 压测 → 另开 change
  - pybind §9.3 PyInstaller frozen exe (需干净 Win PC) → 另开 change
  - 多租户 edge_device 表 (C2) → 远期
- **回滚**: 拨号失败 / 听不到 AI / 听到错音频 → 不破坏现有 deploy；只
  是 "MVP 还没通过"，可继续迭代脚本 + spec Scenario 不需 revert 代码。
  STATE.md 通过证据**不**写入直到真听见 AI 开场白。
