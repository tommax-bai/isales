# web-admin-ui Specification

## Purpose
TBD - created by archiving change web-admin-ui-redesign. Update Purpose after archive.
## Requirements
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

`isales-web` SHALL 在 view 中暴露以下 backend 已 spec 的能力（本 change 把 prompt 配置从 4-tier 改为 **3-tier**）：

- 三 LLM prompt 配置（`role-prompt`、`filler`、`goal-achievement`、`ai-pipeline`）— 在 **campaign 详情 view** 中按 3 个 tier（**main 对话主 LLM / referee 决策旁路 LLM / extractor 信息抽取 LLM**）分组，per-campaign 增删改 + enable switch + temperature/topP 滑杆 + provider/model 选择器。**删除原 4-tier 中的 judge / polish 编辑区**。
- 可通话时段配置（`time-window`）— 在 **campaign 详情 view** 中以多个时段卡片形式列出，每段含开始时间、结束时间、周一至周日 7 个 checkbox，写入该 `campaign.time_windows`
- AI 服务商凭据管理（`provider-abc` + `provider-credential`）— 在「模型厂商」view 中统一管理 LLM / ASR / TTS provider，按 provider 分卡片，含 API key 密码输入 + endpoint + 默认 model + enable switch + 状态徽标。**凭据 SHALL 通过 `/api/provider-credentials` admin API 直接落库**（`provider_credential` 表，Fernet 加密；MUST NOT 用 localStorage 兜底）。UI 仅显示 mask preview，改 key = 整段替换。volcengine 一套 app_key/token 同时供 LLM / ASR / TTS（凭据一体，故不为 ASR/TTS 单设 view）；ASR/TTS provider 为引擎进程级全局，非 per-campaign
- ASR 完整对话内容（`transcript`）— 在外呼记录 view 的每条记录上以可折叠面板展示，AI 与客户消息用左右气泡区分
- 目标达成评分（`goal-achievement`）— 在外呼记录卡片中展示评分、客户意向、是否成功预约、已覆盖的关键要点列表。**`extracted` 字段从 `call_summary.extracted_fields` 改读 `call_record.extracted`**（post-call extractor 异步写入）

#### Scenario: 三 LLM prompt 编辑（per-campaign）

- **WHEN** 用户在 campaign 详情 view 添加 / 编辑 main / referee / extractor 三个 LLM 之一
- **THEN** 表单 SHALL 提供 name / model provider / model name / temperature(0–2) / topP(0–1) / prompt 文本 / enable 开关；保存后 SHALL 通过 admin API 写入归属该 campaign 的 `role_config (kind=<main|referee|extractor>)` + `prompt_version (scope_type=<main|referee|extractor>)`
- **AND** UI MUST NOT 暴露 `judge` / `polish` 类型的 role_config 编辑入口

#### Scenario: main prompt 编辑器提示纯文本输出

- **WHEN** 用户在 campaign 详情 view 编辑 main role 的 prompt
- **THEN** 编辑器右侧 SHALL 显示提示卡片"main LLM 输出必须是纯文本，不要 JSON / markdown / emoji"；MUST NOT 强制注入约束段（保 Campaign 自由度，按 `role-prompt` § "Prompt 由 Campaign 完全自定义"）

#### Scenario: referee prompt 编辑器提示 JSON 输出

- **WHEN** 用户编辑 referee role 的 prompt
- **THEN** 编辑器 SHALL 显示提示"referee 必须输出严格 JSON {decision, goal_type, confidence}"；编辑器 SHALL 提供"插入推荐模板"按钮（一键填入 § role-prompt § "referee prompt 内容规范" 的模板）

#### Scenario: extractor prompt 编辑器提示字段 schema

- **WHEN** 用户编辑 extractor role 的 prompt
- **THEN** 编辑器 SHALL 显示提示"extractor 输出 JSON，字段 schema 自定义"；MAY 提供 schema 字段表（field_name + type + nullable）辅助生成 prompt 段

#### Scenario: provider 选项对齐引擎实装

- **WHEN** 用户在 prompt 配置或 provider 配置中选择 model provider
- **THEN** 可选项 SHALL 对齐 `isales-engine` factory 实装的 provider（LLM：volcengine / openai / mock），MUST NOT 列出引擎未对接的 provider
- **AND** main 用大模型（如 doubao-pro / gpt-4o），referee 与 extractor MAY 推荐用便宜小模型（如 qwen-turbo / gpt-4o-mini / doubao-lite），编辑器 SHALL 在 model 选择器 hover 时显示"main 推荐 ⭐⭐⭐ / referee 推荐 ⭐ / extractor 推荐 ⭐"

#### Scenario: 模型厂商配置写入 DB

- **WHEN** 用户在「模型厂商」view 输入 / 修改 / 删除一个 provider 的 api_key / app_key / app_token / endpoint / default_model / enabled
- **THEN** UI SHALL 调用 `/api/provider-credentials` POST / DELETE 接口；后端 SHALL Fernet 加密后 upsert 行；UI MUST NOT 把任何 provider 密钥写入 localStorage

#### Scenario: API key 仅显示 mask preview

- **WHEN** 用户进入「模型厂商」view 看到已配置的 provider 卡片
- **THEN** API key / app_token 等敏感字段输入框 SHALL 显示 `<前 4 字符>********<后 4 字符>` 形式；MUST NOT 显示明文；改密钥 SHALL 整段替换

#### Scenario: 通话气泡显示

- **WHEN** 用户在外呼记录中点击"查看通话内容"
- **THEN** SHALL 展开可折叠区域，按 transcript 顺序逐条渲染气泡，AI 消息靠左、客户消息靠右，气泡上方 SHALL 显示角色标签

### Requirement: 设计 token 与主题

`isales-web` SHALL 引入独立的 `src/styles/design-tokens.css` 文件承载设计 token，并通过 Element Plus SCSS theme override 与 CSS variable 注入将 token 应用到组件。token SHALL 包含 Figma 设计稿中的色彩、圆角、字号、字重定义。

#### Scenario: 主色 token

- **WHEN** 应用 token
- **THEN** `--isales-primary` SHALL 等于 `#030213`，`--isales-radius` SHALL 等于 `0.625rem`，`--isales-font-size-base` SHALL 等于 `14px`（中文密致基线）

#### Scenario: 状态色 token

- **WHEN** 渲染线索状态、外呼结果、预约状态、客户意向等 badge
- **THEN** SHALL 使用 token 中定义的语义色（new=blue, contacted=yellow, interested=green, appointed=purple, visited=gray, lost=red 等），各色 SHALL 同时有 100/700/800 三档（背景 / 边框 / 文字）

#### Scenario: 暗色主题预留

- **WHEN** 当前阶段
- **THEN** design-tokens.css MUST 同时定义 `:root` 与 `.dark` 两组变量；但 `.dark` SHALL NOT 被自动激活（v1.0 范围内仅亮色），等后续 change 单独引入主题切换

### Requirement: 图标库切换

被重做的 6 个客户面 view + 新顶部导航 SHALL 使用 `lucide-vue-next` 图标库。未被重做的运营 view 可继续使用 `@element-plus/icons-vue`。

#### Scenario: 客户面 view 的图标

- **WHEN** 任一客户面 view 渲染图标
- **THEN** 图标组件 SHALL 来自 `lucide-vue-next`（如 `Phone`, `Users`, `Calendar`, `Settings`, `Key`, `Waves`, `LayoutGrid`, `Mic`, `Volume2`, `Music`, `Target`, `CheckCircle`, `XCircle`, `MessageSquare`, `Plus`, `Trash2`, `Save`, `Edit`, `Eye`, `EyeOff` 等）

#### Scenario: 依赖管理

- **WHEN** 添加 `lucide-vue-next` 依赖
- **THEN** `isales-web/package.json` SHALL 新增该依赖；MUST NOT 同时移除 `@element-plus/icons-vue`（运营 view 仍在用）

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

外呼策略配置 SHALL 绑定到具体 campaign 并持久化到后端，不再是全局配置。campaign 详情 view SHALL 承载以下 per-campaign 配置：**3-tier 串行 LLM（main / referee / extractor）**、可拨时段、选用音色、**filler_enabled toggle**。配置 SHALL 通过 admin API 持久化（`role_config` / `prompt_version` / `filler_set` / `filler_phrase` 按 campaign 写入；`campaign.time_windows` / `campaign.voice_id` / `campaign.filler_enabled` 通过 campaign PATCH 写入），MUST NOT 仅存于浏览器 localStorage。

#### Scenario: 配置入口先选定 campaign

- **WHEN** 用户要编辑 AI 外呼策略
- **THEN** SHALL 先进入某个 campaign 的详情 view，配置区操作的对象 SHALL 明确归属该 campaign

#### Scenario: 三 LLM prompt 编辑（per-campaign）

- **WHEN** 用户在 campaign 详情的 AI 外呼配置区编辑 main / referee / extractor 之一
- **THEN** 表单 SHALL 提供 name / model provider / model name / temperature(0–2) / topP(0–1) / prompt 文本 / enable 开关；保存后 SHALL 通过 admin API 写入归属该 `campaign_id` 的 `role_config` + `prompt_version`，kind / scope_type ∈ `{main, referee, extractor}`

#### Scenario: filler_enabled toggle

- **WHEN** 用户在 campaign 详情 view 切换 filler 启用开关
- **THEN** UI SHALL 调 campaign PATCH API 写入 `campaign.filler_enabled` 字段（bool, default false）；切到 false 时同 page 隐藏 filler_set / filler_phrase 编辑区
- **AND** UI SHALL 在 filler 区上方显示提示"streaming 主链路首音频 ~500ms，filler 仅在用慢模型时建议启用"

#### Scenario: 时段与音色

- **WHEN** 用户在 campaign 详情编辑可拨时段或选用音色
- **THEN** 可拨时段 SHALL 写入该 `campaign.time_windows`；音色 SHALL 从全局音色库（`voice_model`）中选择并写入 `campaign.voice_id`

#### Scenario: 配置持久化替代 localStorage

- **WHEN** 用户保存某 campaign 的外呼策略后刷新页面
- **THEN** 配置 SHALL 从后端重新加载并保持一致

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


### Requirement: 开场白文案试听

管理端场景编辑的「基础」配置 SHALL 允许运营在保存前对"当前开场白文案 + 当前音色"现合成语音并在浏览器试听，无需真实拨号。试听 MUST 使用表单当前（可能未保存）的 `greeting` 与 `voice_id`，且 MUST NOT 写入或依赖已持久化的 campaign 记录。

#### Scenario: 文案与音色齐备时可试听

- **WHEN** 运营在场景编辑「基础」tab 填写了非空"开场白文案"并填定了"音色 ID"，点击"试听"
- **THEN** 系统 SHALL 调用后端合成端点，取回浏览器可直接播放的音频并播放该句开场白；播放期间按钮 MUST 呈现 loading 态

#### Scenario: 文案或音色缺失时禁用试听

- **WHEN** "开场白文案"为空或未填"音色 ID"
- **THEN** "试听"按钮 MUST 处于 disabled 状态，不发起合成请求

#### Scenario: 合成失败给出可读反馈

- **WHEN** 后端合成端点返回错误（音色无效 / 凭据缺失 / vendor 失败 / 超长）
- **THEN** 前端 MUST 展示可读错误提示且不崩溃，按钮 MUST 退出 loading 态可重试

### Requirement: 开场白试听合成端点

isales-api SHALL 提供一个无状态的开场白试听合成端点：入参为文案与音色，输出浏览器可直接播放的音频；端点 MUST 经现有管理端鉴权，MUST NOT 读写 campaign 持久化数据。

#### Scenario: 合成并返回可播放音频

- **WHEN** 已认证管理端用户以 `{text, voice_id}` 请求试听端点，且 `text` 非空且不超过长度上限
- **THEN** 端点 SHALL 用现有 `provider_credential` 凭据合成 TTS，并以浏览器可直接播放的音频内容类型返回

#### Scenario: 拒绝超长或缺参请求

- **WHEN** `text` 为空、超过长度上限，或 `voice_id` 缺失
- **THEN** 端点 MUST 返回校验错误（4xx），MUST NOT 调用 TTS 供应商

#### Scenario: 音色无效返回可纠正错误

- **WHEN** vendor 因音色 ID 无效 / 未授权而拒绝合成
- **THEN** 端点 MUST 返回 4xx（非 5xx）并记录 vendor 错误详情，使前端能提示用户更正音色 ID

#### Scenario: 未认证拒绝

- **WHEN** 请求未携带有效管理端身份
- **THEN** 端点 MUST 拒绝（401/403），MUST NOT 消耗供应商配额
