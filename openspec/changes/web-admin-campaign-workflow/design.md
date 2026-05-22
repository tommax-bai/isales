## Context

`web-admin-ui-redesign`（已上线 ECS）把客户面 IA 定为 3 主入口
`[线索｜外呼｜预约]` + 3 圆形配置按钮 `[AI外呼配置｜ASR-TTS通路｜模型厂商]`，
campaign 被收进 `/operations/campaigns` 运营子区。

数据模型现实（`data-model` spec）：
- `campaign` 表持有 `time_windows`、`concurrency`、`voice_id` 及数十个外呼
  行为字段。
- `role_config.campaign_id` —— 4-tier prompt（role/judge/polish）是
  per-campaign。
- `filler_set.campaign_id` —— 垫词是 per-campaign。
- `voice_model` —— 全局音色库，**无** `campaign_id`；campaign 通过
  `campaign.voice_id` 引用其一。
- ASR/TTS provider —— `isales-engine` 的 `factory.KNOWN_*_PROVIDERS` 是
  引擎进程级全局，非 per-campaign。
- `scheduler` 只派发 `status ∈ {new, retrying, following_up}` 且
  `next_call_at <= now` 且所属 campaign 在 active 集合的 lead。

约束：技术栈不变（Vue 3 + Element Plus + Pinia）；沿用
`isales-web/STYLE_GUIDE.md`；不回炉 `web-admin-ui-redesign`。

## Goals / Non-Goals

**Goals:**
- 把 campaign 作为"场景"接回客户面，成为工作流第一环。
- per-campaign 外呼策略配置（4-tier prompt / 垫词 / 时段 / 选用音色）落到
  campaign 详情页，并真持久化到后端。
- 客户能从客户面创建场景、配置、启停。
- 添加线索时从下拉选 campaign，不再手填数字 ID。
- 修掉 LeadList「外呼」按钮的 `queued` dead-state bug。

**Non-Goals:**
- 不改 campaign 的后端行为 / 数据模型 / 状态机。
- 不做多租户场景隔离（v1 roadmap 另议）。
- 不实现"单条线索立即外呼"的后端能力（见 D4）。
- 不重写运营面 `CampaignEdit.vue` 的高级字段编辑。
- `provider_credential` 后端表仍不做（API key 继续走 env）。

## Decisions

### D1：「场景」作为客户面第 4 个主入口

顶部导航主入口 3 → 4：`[场景｜线索｜外呼｜预约]`，"场景"在最左（工作流
起点）。配置圆按钮 3 → 1：只保留「模型厂商」（全局平台凭据，见 D2）。

**Alternatives:** ①「场景」做成强制前置层级（进系统先选场景再看线索/外呼/
预约）——更适合多场景大客户，但 v1.0 小客户试点通常 1–2 个 campaign，强制
层级是多余的一步，否决。② 维持 3 入口、campaign 塞进某入口——campaign 是
独立工作流阶段，塞附属位置语义不清，否决。

### D2：per-campaign 配置 vs 全局资源的边界

用户决策"每个 campaign 独立配"落地为：

| 配置 | 归属 | UI 落点 |
|---|---|---|
| 4-tier 并行 prompt（role_config + prompt_version） | per-campaign | campaign 详情页 |
| 垫词（filler_set + filler_phrase） | per-campaign | campaign 详情页 |
| 可拨时段（campaign.time_windows） | per-campaign | campaign 详情页 |
| 选用音色（campaign.voice_id） | per-campaign（引用） | campaign 详情页（下拉选） |
| 并发上限等 campaign 字段 | per-campaign | campaign 详情页 |
| 音色库（voice_model 增删） | **全局** | 运营面（已有 voice-models view） |
| ASR/TTS provider 通路 | **全局**（引擎进程级） | 全局配置（或运营面） |
| 模型厂商 API key | **全局**（平台凭据） | 顶部「模型厂商」圆按钮，保留 |

即：**外呼策略 per-campaign，基础资源（音色库 / provider / 厂商凭据）全局**，
campaign 详情页对基础资源是"选用"而非"管理"。原全局 `AICallConfig` 拆解进
campaign 详情；原 `VoiceChannelConfig` 的 ASR/TTS provider 部分降为全局配置、
音色库部分并入运营面 voice-models。

### D3：campaign 客户向 view —— 列表 + 详情，新建而非复用 CampaignEdit

- `/campaigns`（客户面）：campaign 卡片列表，每卡显示名称 / 启停状态徽标 /
  线索数 / 外呼进度概览；「新建场景」入口。
- `/campaigns/:id`（客户面详情）：基本信息 + per-campaign 配置（D2 上半表）+
  启停按钮 + 进度。
- 运营面 `/operations/campaigns` 的 `CampaignEdit.vue`（数十个高级字段）
  **保留不动**，供平台运营调高级参数。客户面详情页只暴露工作流必需字段，
  避免把 33KB 的全字段表单丢给客户。

**Alternatives:** 复用 `CampaignEdit.vue`——它是运营全字段表单，客户向体验
过载，否决。

### D4：LeadList「外呼」按钮 —— v1 移除单条外呼，外呼走 campaign 启停

当前按钮把 lead 写成 `queued`，scheduler 不扫描该状态（dead bug）。iSales
是 campaign 驱动的批量外呼，无"单条立即外呼"后端能力。本 change：移除
LeadList 卡片的「外呼」按钮，外呼统一由 campaign 详情页的「启动场景」触发
批量调度。线索卡片主操作回归「编辑」。

单条「立即试呼」如后续需要，作为独立 change 新增后端
`POST /leads/{id}/dial` —— 不在本 change 范围。

### D5：campaign 启动时初始化 lead.next_call_at

`scheduler` 要求 `next_call_at <= now`，但新建 / 导入的 lead
`next_call_at = NULL`，无任何代码初始化它。为让"客户启动场景 → 线索真被
外呼"链路闭合，`isales-api` 的 campaign start 流程 SHALL 在启动时把该
campaign 下 `status = new` 且 `next_call_at IS NULL` 的 lead 批量
`SET next_call_at = now`。

这是落在 `isales-api` 的补丁式逻辑，不改 scheduler。`retry-followup` spec
未覆盖"首次入队 next_call_at 初始化"——见 Open Questions。

### D6：后端 admin 端点参照既有 router 模式

`isales-api` 新增 `role_config` / `prompt_version` / `filler_set` /
`filler_phrase` 4 组 router，CRUD 形态对齐 `leads.py` / `appointments.py`
（JWT 鉴权、`Page[...]` 分页、按 `campaign_id` 过滤）。4 张表的 SQLAlchemy
模型与 Pydantic schema 已存在于 `isales-common`，预计无需 bump common。

### D7：变更顺序依赖

`web-admin-ui` capability 仍在未归档的 `web-admin-ui-redesign` change 内。
本 change 的 `web-admin-ui` delta 以 `web-admin-ui-redesign` **先归档**
（spec 合并进 `openspec/specs/web-admin-ui/`）为前提。实施顺序：
先 archive `web-admin-ui-redesign` → 再 apply 本 change。

## Risks / Trade-offs

- **[Risk] per-campaign 配置重构废弃 web-admin-ui-redesign 的全局
  localStorage 数据** → Mitigation：那批配置本就是"后端未就绪"的临时兜底
  （design.md Open Q §2 已声明），用户尚未实际依赖；本 change 一并补上后端
  端点，localStorage 兜底退场。
- **[Risk] D5 的 next_call_at 批量初始化与 `retry-followup` scheduler 数据流
  的写入归属约定相邻** → Mitigation：只在 campaign start 这一个时点、只针对
  `status=new ∧ next_call_at IS NULL` 的 lead 写入，不与 scheduler 的窗外
  重排 / worker 的 retry-followup 写入冲突；design 在 Open Questions 标注，
  实施前于 retry-followup spec 增补一条 Scenario 或确认无需。
- **[Risk] campaign 详情页若把 role_config CRUD 做成逐条同步，交互碎** →
  Mitigation：沿用 `web-admin-ui-redesign` 的 tier 批量保存 + 乐观更新模式。
- **[Trade-off] 客户面 campaign 详情只暴露子集字段，与运营面 CampaignEdit
  字段不一致** → 可接受：两类人格（客户 vs 平台运营）本就需要不同粒度。

## Migration Plan

1. **前置**：归档 `web-admin-ui-redesign`（D7）。
2. **后端**（isales-api）：4 组 admin CRUD router + campaign start 的
   next_call_at 初始化（D5/D6）；pytest 覆盖。
3. **前端 IA**（isales-web）：TopNav 4 主入口 + 1 配置按钮；router 增
   `/campaigns`、`/campaigns/:id`。
4. **前端 view**：campaign 列表 + 详情页（含 per-campaign 配置区）；
   `AICallConfig` 逻辑迁入详情页；`VoiceChannelConfig` 拆分（provider 降全局
   / 音色库并运营面）；`LeadEditDialog` campaign 下拉；移除 LeadList 外呼
   按钮。
5. **部署**：rebuild `dist/` → rsync ECS → 重启 `isales-api`（无 DB 迁移）。
6. **回滚**：前端 `git revert` + redeploy 旧 `dist/`；后端新 router 为
   纯新增，回滚即移除路由挂载。

## Open Questions

1. **D5 的 next_call_at 初始化是否需要 `retry-followup` spec delta** —— 该
   spec 当前未规定"首次入队"的 next_call_at 由谁写。倾向：本 change 在
   `retry-followup` 增补一条 Scenario 明确"campaign 启动时 api 初始化首呼
   next_call_at"。apply 前确认。
2. **ASR/TTS provider 全局配置 view 的最终落点** —— 降为独立全局 view 还是
   并入运营面？D2 暂定"全局"，具体 view 归属在 specs 阶段定。
3. **campaign 详情页外呼"进度"展示的数据来源** —— 复用 `analytics` 端点还是
   新增按 campaign 聚合的查询；specs 阶段定。
