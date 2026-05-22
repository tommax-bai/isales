## ADDED Requirements

### Requirement: 顶级信息架构 — 客户工作流四入口 + 模型厂商配置

`isales-web` 管理后台 SHALL 以**客户外呼工作流**组织顶层导航。顶部 sticky
header SHALL 提供胶囊式分段控件，包含**四个主入口**（场景 / 线索 / 外呼 /
预约）+ **一个圆形配置按钮**（模型厂商）。"场景"SHALL 位于主入口序列最左，
作为客户工作流的起点（建场景 → 灌线索 → 外呼 → 收预约）。

per-campaign 的外呼策略配置（AI 外呼配置 / 通路）不再是独立顶级入口，已
并入 campaign 详情页（见 Requirement「per-campaign 外呼策略配置」）；仅
"模型厂商"作为平台级全局凭据保留为圆形配置按钮。

#### Scenario: 顶部导航的固定结构

- **WHEN** 用户登录后进入任意 `/` 下的子路由
- **THEN** 页面顶部 SHALL 显示固定（sticky）导航栏，左侧 logo + 标题，中间
  胶囊容器中 SHALL 仅包含四个文本+图标按钮 `[场景｜线索｜外呼｜预约]`，
  右侧 SHALL 仅包含一个圆形图标按钮（模型厂商）

#### Scenario: 当前激活态视觉反馈

- **WHEN** 用户切换到任一主入口或配置入口
- **THEN** 被选中的按钮 SHALL 显示白色背景 + 主色文字 + 微阴影；其余按钮
  SHALL 显示灰色文字、透明背景

#### Scenario: 移动端折叠

- **WHEN** 视口宽度 < 768px
- **THEN** 中间业务导航 SHALL 隐藏，配置入口 SHALL 保留可见

### Requirement: campaign 客户向管理 view

`isales-web` 客户面 SHALL 提供 campaign（外呼"场景"）的列表与详情 view，
使客户无需进入运营子区即可创建、配置、启停 campaign。运营面
`/operations/campaigns` 的全字段高级编辑（`CampaignEdit.vue`）SHALL 保留
不变，供平台运营调整高级参数。

#### Scenario: 场景列表

- **WHEN** 用户点击顶部导航"场景"入口（`/campaigns`）
- **THEN** SHALL 显示 campaign 卡片列表，每卡 SHALL 显示场景名称、启停状态
  徽标、归属线索数、外呼进度概览；列表顶部 SHALL 提供"新建场景"入口

#### Scenario: 场景详情

- **WHEN** 用户点击某个 campaign 卡片（`/campaigns/:id`）
- **THEN** SHALL 进入该 campaign 的详情 view，展示基本信息 + per-campaign
  外呼策略配置区 + 启停控制 + 外呼进度

#### Scenario: 客户面与运营面字段分层

- **WHEN** 客户在客户面 campaign 详情 view 编辑场景
- **THEN** 该 view SHALL 仅暴露工作流必需字段（名称、选用音色、4-tier
  prompt、垫词、可拨时段、并发上限、启停）；数十个高级行为字段（静音 /
  打断 / 转人工 / 重试等）SHALL NOT 出现在客户面，仅在运营面
  `CampaignEdit.vue` 可编辑

### Requirement: per-campaign 外呼策略配置

外呼策略配置 SHALL 绑定到具体 campaign 并持久化到后端，不再是全局配置。
campaign 详情 view SHALL 承载以下 per-campaign 配置：4-tier 并行 prompt
（对话策略 / 质量判别 / 润色 / 垫词）、可拨时段、选用音色。配置 SHALL
通过 admin API 持久化（`role_config` / `prompt_version` / `filler_set` /
`filler_phrase` 按 campaign 写入；`campaign.time_windows` /
`campaign.voice_id` 通过 campaign PATCH 写入），MUST NOT 仅存于浏览器
localStorage。

#### Scenario: 配置入口先选定 campaign

- **WHEN** 用户要编辑 AI 外呼策略
- **THEN** SHALL 先进入某个 campaign 的详情 view，配置区操作的对象 SHALL
  明确归属该 campaign；不存在脱离 campaign 的"全局 AI 外呼配置"入口

#### Scenario: 多并行 prompt 编辑（per-campaign）

- **WHEN** 用户在 campaign 详情的 AI 外呼配置区添加一条对话策略
- **THEN** 表单 SHALL 提供 name / model provider / model name /
  temperature(0–2) / topP(0–1) / prompt 文本 / enable 开关；保存后 SHALL
  通过 admin API 写入归属该 `campaign_id` 的 `role_config` + `prompt_version`

#### Scenario: 时段与音色

- **WHEN** 用户在 campaign 详情编辑可拨时段或选用音色
- **THEN** 可拨时段 SHALL 写入该 `campaign.time_windows`；音色 SHALL 从全局
  音色库（`voice_model`）中选择并写入 `campaign.voice_id`——音色库本身的
  增删属全局资源管理，不在 campaign 详情内

#### Scenario: 配置持久化替代 localStorage

- **WHEN** 用户保存某 campaign 的外呼策略后刷新页面
- **THEN** 配置 SHALL 从后端重新加载并保持一致；`web-admin-ui-redesign`
  落地的全局 localStorage 配置兜底 SHALL 退场

### Requirement: 添加线索绑定 campaign

`isales-web` 的线索新建 / 编辑对话框 SHALL 通过 campaign 下拉选择器指定线索
归属的 campaign，MUST NOT 要求用户手填 campaign 数字 ID。

#### Scenario: campaign 下拉选择

- **WHEN** 用户打开新建线索对话框
- **THEN** "归属场景"字段 SHALL 是下拉选择器，选项 SHALL 显示 campaign
  名称与启停状态；选中未启动的 campaign SHALL 给出"该场景未启动，线索暂不
  会被外呼"的提示

#### Scenario: 无 campaign 时的引导

- **WHEN** 系统中尚无任何 campaign 且用户尝试新建线索
- **THEN** 对话框 SHALL 提示先创建场景，并提供跳转"场景"入口的链接

#### Scenario: 编辑线索时 campaign 锁定

- **WHEN** 用户编辑已存在的线索
- **THEN** 归属 campaign SHALL 锁定不可改（改归属会破坏 retry/follow-up
  历史）

### Requirement: campaign 启动驱动批量外呼

外呼 SHALL 由 campaign 启停驱动的批量调度触发，客户面 MUST NOT 提供"单条
线索立即外呼"的按钮（iSales 无该后端能力）。客户从 campaign 详情启动场景
后，该 campaign 下的待呼线索 SHALL 能进入 scheduler 的调度范围。

#### Scenario: 移除单条外呼按钮

- **WHEN** 渲染线索卡片
- **THEN** 卡片 MUST NOT 显示"外呼"按钮；线索卡片的操作 SHALL 为编辑 /
  删除

#### Scenario: 启动场景

- **WHEN** 用户在 campaign 详情点击"启动场景"
- **THEN** 该 campaign SHALL 进入 active 状态；该 campaign 下的待呼线索
  （含 `next_call_at` 为空的新线索）SHALL 随即进入 scheduler 的调度范围
  ——`next_call_at IS NULL` 由 scheduler 取数视为"立即可呼"（见
  `retry-followup` spec「scheduler 调度数据流」），无需在 lead 创建时
  预先初始化 `next_call_at`

#### Scenario: 停止场景

- **WHEN** 用户在 campaign 详情点击"停止场景"
- **THEN** 该 campaign SHALL 退出 active 状态，scheduler MUST NOT 再为其
  派发新线索

## MODIFIED Requirements

### Requirement: 客户面 view 清单

`isales-web` SHALL 实现以下客户视角 view：

| 入口 | 路由 | view 文件 |
|---|---|---|
| 场景管理 | `/campaigns` | `views/Campaigns/CampaignList.vue`（客户面，新增） |
| 场景详情 | `/campaigns/:id` | `views/Campaigns/CampaignDetail.vue`（新增） |
| 线索管理 | `/leads` | `views/Leads/LeadList.vue` |
| 外呼记录 | `/calls` | `views/Calls/CallList.vue` + `views/Calls/CallDetail.vue` |
| 预约管理 | `/appointments` | `views/Appointments/AppointmentList.vue` |
| 模型厂商 | `/config/model-providers` | `views/Config/ModelProviderConfig.vue` |

`web-admin-ui-redesign` 引入的全局 `AICallConfig.vue` 的功能 SHALL 迁入
campaign 详情 view（per-campaign）；`VoiceChannelConfig.vue` SHALL 拆分——
ASR/TTS provider 配置降为全局配置、音色库管理并入运营面 voice-models view。

#### Scenario: 顶部入口的路由对应

- **WHEN** 用户点击顶部导航中的某个入口
- **THEN** 浏览器 URL SHALL 切换到上述路由表中对应的路径，view 内容 SHALL
  仅渲染该 view 的组件

#### Scenario: 场景详情的二级布局

- **WHEN** 用户从场景列表进入某个 campaign 详情
- **THEN** 主内容区 SHALL 显示带标题的 page header，下方分区加载基本信息与
  per-campaign 配置组件

### Requirement: 运营面 view 收纳

非客户工作流的运营管理 view SHALL 通过顶部导航的 overflow 子菜单（或独立的
`/operations` 子区索引页）访问。这些 view 包括数据看板 / 通话监控 / 回调
配置 / 回调记录 / 转人工任务 / 节假日 / 设备 / SIM 卡 / 音色库 / campaign
高级编辑，其功能 MUST 保持完整，仅入口位置改变。campaign 的客户向管理已移至
客户面（见 Requirement「campaign 客户向管理 view」），运营面保留的是
campaign 全字段高级编辑。

#### Scenario: 收纳后的 view 仍可访问

- **WHEN** 用户从顶部导航打开 overflow 菜单或访问 `/operations`
- **THEN** SHALL 看到完整的运营 view 列表（Dashboard / Monitor / Callback
  Configs / Callback Logs / Handoff Tasks / Holidays / Devices / SIM Cards /
  Voice Models / Campaign 高级编辑），点击任一链接 SHALL 进入对应 view

#### Scenario: 路由迁移

- **WHEN** 用户访问旧的运营路由（`/dashboard`, `/devices`, `/sim-cards`,
  `/holidays`, `/callback-configs`, `/callback-logs`, `/handoff-tasks`,
  `/monitor/:id`）
- **THEN** 服务 SHALL 永久重定向（301 等价的客户端 `router.beforeEach`
  重定向）到 `/operations/<原路径>`，保留旧链接可用性
- **AND** `/campaigns` SHALL NOT 再被重定向——它现为客户面 campaign 列表的
  正式路由；campaign 的运营面高级编辑使用 `/operations/campaigns/:id/edit`

### Requirement: 已 spec 能力的 UI 暴露

`isales-web` SHALL 在 view 中暴露以下 backend 已 spec 的能力：

- 多并行 prompt 配置（`role-prompt`、`filler`、`goal-achievement`、
  `ai-pipeline`）— 在 **campaign 详情 view** 中按 4 个 tier（对话策略 /
  垫词 / 质量判别 / 润色）分组，per-campaign 增删改 + enable switch +
  temperature/topP 滑杆 + provider/model 选择器
- 可通话时段配置（`time-window`）— 在 **campaign 详情 view** 中以多个时段
  卡片形式列出，每段含开始时间、结束时间、周一至周日 7 个 checkbox，写入
  该 `campaign.time_windows`
- AI 服务商凭据管理（`provider-abc`）— 在「模型厂商」view 中统一管理 LLM /
  ASR / TTS provider（provider 凭据一体，volcengine 一套 app_key/token 三路
  通用，故不为 ASR/TTS 单设 view）：按 provider 分卡片，含 API key 密码输入
  （带显示/隐藏 toggle 与掩码预览）+ endpoint 输入 + 默认 model + enable
  switch + 状态徽标；ASR/TTS provider 为引擎进程级全局，非 per-campaign
- ASR 完整对话内容（`transcript`）— 在外呼记录 view 的每条记录上以可折叠
  面板展示，AI 与客户消息用左右气泡区分
- 目标达成评分（`goal-achievement`）— 在外呼记录卡片中展示评分、客户意向、
  是否成功预约、已覆盖的关键要点列表

#### Scenario: 多并行 prompt 编辑（per-campaign）

- **WHEN** 用户在 campaign 详情 view 添加一条新的对话策略
- **THEN** 表单 SHALL 提供 name / model provider / model name /
  temperature(0–2) / topP(0–1) / prompt 文本 / enable 开关；保存后 SHALL
  通过 admin API 写入归属该 campaign 的 `role_config` + `prompt_version`

#### Scenario: provider 选项对齐引擎实装

- **WHEN** 用户在 prompt 配置或 provider 配置中选择 model provider
- **THEN** 可选项 SHALL 对齐 `isales-engine` factory 实装的 provider
  （LLM：volcengine / openai / mock），MUST NOT 列出引擎未对接的 provider

#### Scenario: 通话气泡显示

- **WHEN** 用户在外呼记录中点击"查看通话内容"
- **THEN** SHALL 展开可折叠区域，按 transcript 顺序逐条渲染气泡，AI 消息
  靠左、客户消息靠右，气泡上方 SHALL 显示角色标签

## REMOVED Requirements

### Requirement: 顶级信息架构 — 客户工作流三入口 + 配置三按钮

**Reason**：campaign（外呼"场景"）接入客户工作流后，主入口由三个（线索 /
外呼 / 预约）扩展为四个（场景 / 线索 / 外呼 / 预约）；AI 外呼配置与 ASR-TTS
通路因改为 per-campaign 而不再是独立顶级配置入口，圆形配置按钮由三个减为
一个（模型厂商）。

**Migration**：见新增 Requirement「顶级信息架构 — 客户工作流四入口 +
模型厂商配置」。
