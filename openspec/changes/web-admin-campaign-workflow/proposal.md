## Why

`web-admin-ui-redesign` 把 campaign（外呼"任务/场景"）当作运营 view，收进了
`/operations/campaigns`，客户面 6 个 view 不含 campaign。但 campaign 是客户
外呼工作流的**起点**——外呼策略、可拨时段、并发上限、prompt 版本全挂在
campaign 上，线索必须归属 campaign，scheduler 只派发"已启动 campaign"的线索。
把它藏进运营区导致客户工作流断链：添加线索只能手填 campaign_id 数字、线索加了
不外呼（无启动入口）、`AICallConfig`/`VoiceChannelConfig` 做成"全局配置"的
错觉但底层 `role_config` / `time_window` 都是 per-campaign。

## What Changes

- **campaign 进入客户面**：顶部导航增加"场景/任务"入口（具体形态——第 4 个
  主入口 vs「场景」前置层级——在 design.md 对比后定）。campaign 成为客户工作流
  的第一环：建场景 → 配策略 → 启停 → 灌线索 → 看外呼 → 收预约。
- **NEW campaign 客户向 view**：创建 / 编辑场景、查看启停状态与外呼进度。
  `/operations/campaigns` 的运营视角可保留或合并（design 定）。
- **配置 view 重构为 per-campaign**：`AICallConfig`（4-tier 并行 prompt）、
  `VoiceChannelConfig`（ASR/TTS/音色）、可拨时段，从当前的"全局
  localStorage 暂存"改为**绑定到某个 campaign 的持久化配置**——进入配置前先
  选定 campaign。**BREAKING**：原 `web-admin-ui-redesign` 落地的全局
  localStorage 配置数据废弃。
- **添加线索选 campaign**：`LeadEditDialog` 的"任务 ID"数字输入框换成
  campaign 下拉选择器（显示 campaign 名 + 启停状态）。
- **修正 LeadList「外呼」按钮**：当前把线索写成 `queued`——scheduler 不扫描
  该状态（dead bug）；改为符合 scheduler 调度数据流的正确语义（design 定）。
- **后端补 admin 端点**：`isales-api` 新增 `role_config` / `prompt_version` /
  `filler_set` / `filler_phrase` 的 HTTP CRUD（这些表已存在，仅缺 HTTP 面），
  让 per-campaign 配置可真持久化，替代 localStorage 兜底。

## Capabilities

### New Capabilities

<!-- 无。campaign 的后端行为（状态机、字段、归属）已散落在 retry-followup /
     time-window / role-prompt / ai-pipeline / data-model 等现有 spec，本
     change 不改其行为，只改 UI 如何暴露它。 -->

### Modified Capabilities

- `web-admin-ui`：① 信息架构调整——campaign 从"运营面 view 收纳"移入客户面
  工作流；② 客户面 view 清单新增 campaign 管理 view；③"已 spec 能力的 UI
  暴露"Requirement 深化——AI 外呼配置 / ASR-TTS 通路绑定到具体 campaign 并
  持久化（不再全局 localStorage）。

  **依赖**：`web-admin-ui` capability 目前仍在未归档的 `web-admin-ui-redesign`
  change 内，尚未合并进 `openspec/specs/`。本 change 的 spec delta 以
  `web-admin-ui-redesign` **先归档**为前提——见 design.md「变更顺序依赖」。

## Impact

- **affected repos**：
  - `isales-web`（重）：新 campaign view + 配置 view 重构（per-campaign）+
    TopNav 增加入口 + router 调整 + `LeadEditDialog` campaign 选择器 +
    LeadList 外呼按钮修正。
  - `isales-api`（中）：新增 `role_config` / `prompt_version` /
    `filler_set` / `filler_phrase` 4 组 admin CRUD router。
  - `isales-common`：预计无改动（上述 4 张表的 SQLAlchemy 模型 + Pydantic
    schema 已存在）。
  - `deploy/cloud`：重新部署 `isales-web/dist/` + 重启 `isales-api`；无 DB
    迁移（无新表）。
- **affected specs**：`web-admin-ui` delta。
- **BREAKING**：`web-admin-ui-redesign` 落地的全局配置 localStorage 数据被
  per-campaign 持久化取代；客户面深链可能变动（campaign 入口新增）。
- **依赖的 active change**：`web-admin-ui-redesign` 必须先归档。
- **不变**：realtime engine / edge / telephony / scheduler / worker / gRPC /
  RTC plane；campaign 的后端行为与数据模型。
