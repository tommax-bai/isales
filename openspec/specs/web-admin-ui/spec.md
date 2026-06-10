# web-admin-ui Specification

## Purpose
TBD - created by archiving change web-admin-ui-redesign. Update Purpose after archive.
## Requirements
### Requirement: 客户面 view 清单

`isales-web` SHALL 实现以下客户视角 view（系统单一角色，所有 view 同属「用户」工作台，无运营/客户分区）：

| 入口 | 路由 | view 文件 |
|---|---|---|
| 场景管理 | `/campaigns` | `views/Campaigns/CampaignWorkspace.vue` |
| 场景详情 | `/campaigns/:id` | `views/Campaigns/CampaignDetail.vue` |
| 线索管理 | `/leads` | `views/Leads/LeadList.vue` |
| 外呼记录 | `/calls` | `views/Calls/CallList.vue` + `views/Calls/CallDetail.vue` |
| 数据看板 | `/dashboard` | `views/DashboardView.vue`（由运营区升为客户顶级入口） |
| 模型厂商 | `/config/model-providers` | `views/Config/ModelProviderConfig.vue` |

预约管理 view 已随 change `admin-prune-vestigial-features` 删除（预约功能整体下线）。低频但后端已实装的 view（通话监控 `MonitorView` / 节假日 `HolidayList` / 设备在线状态 edge-devices）SHALL 通过顶部导航的「更多/设置」折叠区访问，其功能 MUST 保持完整，仅入口位置改变。音色目录 view 与转人工任务 view 已删除——音色不在本系统编目（campaign 直接填 vendor speaker 串到 `campaign.voice_id`），转人工任务表从未被写入。无对应后端的 view（SIM 卡 / 回调记录 / 回调配置独立页）SHALL 删除；回调能力 SHALL 仅以 per-campaign「回调」tab 形式存在。

#### Scenario: 顶部入口的路由对应

- **WHEN** 用户点击顶部导航中的某个入口
- **THEN** 浏览器 URL SHALL 切换到上述路由表中对应的路径，view 内容 SHALL 仅渲染该 view 的组件

#### Scenario: 已删除入口不出现

- **WHEN** 用户浏览顶部导航与「更多/设置」折叠区
- **THEN** MUST NOT 出现「预约管理」「音色目录」「转人工任务」任一入口；访问其旧路由 SHALL 不再命中任何 view

#### Scenario: 场景详情的二级布局

- **WHEN** 用户从场景列表进入某个 campaign 详情
- **THEN** 主内容区 SHALL 显示带标题的 page header，下方分区加载基本信息与 per-campaign 配置组件

#### Scenario: 场景列表可删除场景

- **WHEN** 用户在场景列表（`/campaigns`）的某张场景卡片上触发删除
- **THEN** SHALL 弹出二次确认；确认后 SHALL 调用 `campaignsApi.delete` 删除该 campaign 并从列表移除；MUST NOT 需要进入任何运营区完成删除

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

### Requirement: campaign 客户向管理 view

`isales-web` SHALL 提供 campaign（外呼"场景"）的列表与详情 view，使用户无需进入任何独立分区即可创建、配置、启停、删除 campaign。campaign 全字段高级编辑（`CampaignEdit.vue`）作为**引擎重设计期的临时例外**保留，改由场景详情进入（不再属于已解散的运营区），待引擎定型后由后续 change 按客户面理念折叠重做。

#### Scenario: 场景列表

- **WHEN** 用户点击顶部导航"场景"入口（`/campaigns`）
- **THEN** SHALL 显示 campaign 卡片列表，每卡 SHALL 显示场景名称、启停状态徽标、归属线索数、外呼进度概览；列表顶部 SHALL 提供"新建场景"入口，每卡 SHALL 提供删除入口

#### Scenario: 场景详情

- **WHEN** 用户点击某个 campaign 卡片（`/campaigns/:id`）
- **THEN** SHALL 进入该 campaign 的详情 view，展示基本信息 + per-campaign 外呼策略配置区 + 启停控制 + 外呼进度

#### Scenario: 高级编辑从场景详情进入

- **WHEN** 用户在 campaign 详情 view 需要编辑客户面未直出的高级行为字段（静音 / 打断 / 转人工 / 重试 等）
- **THEN** SHALL 从场景详情进入保留的全字段高级编辑器；该入口 MUST NOT 经由任何 `/operations` 路由或「运营管理」菜单

### Requirement: per-campaign 外呼策略配置

外呼策略配置 SHALL 绑定到具体 campaign 并持久化到后端，不再是全局配置。campaign 详情 view SHALL 承载以下 per-campaign 配置：**3-tier 串行 LLM（main / referee / extractor）**、可拨时段、选用音色、**filler_enabled toggle 与 filler_delay_ms 触发延迟**。配置 SHALL 通过 admin API 持久化（`role_config` / `prompt_version` 按 campaign 写入；`campaign.time_windows` / `campaign.voice_id` / `campaign.filler_enabled` / `campaign.filler_delay_ms` / `campaign.filler_phrases` 通过 campaign PATCH 写入），MUST NOT 仅存于浏览器 localStorage。

#### Scenario: 配置入口先选定 campaign

- **WHEN** 用户要编辑 AI 外呼策略
- **THEN** SHALL 先进入某个 campaign 的详情 view，配置区操作的对象 SHALL 明确归属该 campaign

#### Scenario: 三 LLM prompt 编辑（per-campaign）

- **WHEN** 用户在 campaign 详情的 AI 外呼配置区编辑 main / referee / extractor 之一
- **THEN** 表单 SHALL 提供 name / model provider / model name / temperature(0–2) / topP(0–1) / prompt 文本 / enable 开关；保存后 SHALL 通过 admin API 写入归属该 `campaign_id` 的 `role_config` + `prompt_version`，kind / scope_type ∈ `{main, referee, extractor}`

#### Scenario: filler_enabled toggle

- **WHEN** 用户在 campaign 详情 view 切换 filler 启用开关
- **THEN** UI SHALL 调 campaign PATCH API 写入 `campaign.filler_enabled` 字段（bool, default false）；切到 false 时同 page 隐藏垫词输入区
- **AND** UI SHALL 在 filler 区上方显示提示"streaming 主链路首音频 ~500ms，filler 仅在用慢模型时建议启用"

#### Scenario: filler_delay_ms 触发延迟

- **WHEN** 用户在 campaign 详情 view 开启 filler 后编辑触发延迟
- **THEN** UI SHALL 展示 `filler_delay_ms` 数值输入（仅 `filler_enabled=true` 时可见），调 campaign PATCH API 写入 `campaign.filler_delay_ms`（int，可空，留空表示 engine 默认 600ms）

#### Scenario: 垫词输入（分号分隔，随 campaign PATCH）

- **WHEN** 用户在 campaign 详情 view 编辑垫词
- **THEN** UI SHALL 展示单行分号分隔输入（参照打断白名单），失焦时解析为 `list[str]`，随页面底部「保存」一起通过 campaign PATCH 写入 `campaign.filler_phrases`（无独立即时端点、无「组」概念）

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

### Requirement: campaign 多流路由配置界面

campaign 配置页 SHALL 提供「多流路由」配置区，包含：① 主对话流（main，单条）；② 重组流（restructure，单条，可不配）；③ 裁判列表（N 个 referee，可增删）；④ 路由规则编辑器；⑤ **人设列表（N 个 persona，可增删，opt-in，cap ≤ 3）**；⑥ **工具配置（hangup / transfer，见 § "工具配置界面（ToolsTab）"）**。每个裁判 SHALL 可编辑 label / model / prompt / 输出枚举语义说明。路由规则编辑器 SHALL 让用户按顺序增删规则，每条规则可选「绑定哪个裁判 → 匹配哪些 category → 执行什么 action」；action SHALL 支持 路由到角色(persona) / 工具(挂断·转人工) / 状态转移 / 切重组流，并可选 `then_state` 目标。

#### Scenario: 增删裁判

- **WHEN** 用户在裁判列表点「添加裁判」
- **THEN** 界面 SHALL 新增一行可编辑 referee（label / model / prompt），保存后落 `kind=referee` role_config
- **AND** 删除某裁判时 SHALL 校验无 routing_rules 仍引用其 label，否则提示先改规则

#### Scenario: 路由规则有序编辑

- **WHEN** 用户编辑路由规则
- **THEN** 界面 SHALL 以有序列表呈现规则、支持调整顺序（顺序即优先级），每条规则可选 referee（下拉其 label）+ 匹配 category（多选其枚举）+ action
- **AND** action 编辑器 SHALL 提供四类：① 状态转移（to + goal_type）② 切重组流（source）③ **路由到角色**（route → 下拉 persona label 或内置 closing/recovery/restructure）④ **工具**（tool → 下拉 hangup/transfer alias）；③④ 及①可选 `then_state` 下拉（LISTENING / WRAPPING_UP / ACTIVATING / TRANSFERRING / END）

#### Scenario: 切换 action 目标清空陈旧字段（修 422）

- **WHEN** 用户把某条规则的 action 目标从 `goal_achieved`（带 goal_type）切到其它目标（transfer / route / tool / restructure）
- **THEN** 界面 MUST 清空不再适用的 `goal_type`（及其它陈旧分支字段），使提交载荷只含当前 action 类型的合法字段；MUST NOT 残留 `goal_type` 导致后端 `422` 保存失败（cherry-forward 自 superseded `referee-hangup-action` 的已知 bug 修复）

#### Scenario: 配置重组流

- **WHEN** 用户启用重组流
- **THEN** 界面 SHALL 提供 restructure 的 model + prompt 编辑入口，并提示「输入为被打断残留或上一句要点，prompt 应写重写/包装指令」

#### Scenario: 单裁判向后兼容呈现

- **WHEN** 打开一个仅含单 referee + 默认规则的存量 campaign
- **THEN** 界面 SHALL 正常呈现该单裁判与等价默认规则，用户 MAY 在此基础上加裁判/规则，存量配置 MUST NOT 被破坏

### Requirement: Campaign greeting 编辑入口

isales-web MUST 在 campaign 编辑表单提供 greeting 字段编辑控件，让运营人员可输入 /
修改 / 清空 campaign-level 固定开场白文案。保存后下次该 campaign 发起 dial 时 engine
SHALL 通过 `load_runtime_config` 拿到新文案，MUST NOT 需要 engine 重启。控件位置（客
户面 CampaignDetail.vue 或运营面 `/operations/campaigns/:id/edit`）由实施 task 阶段
audit 决定。

#### Scenario: 表单包含 greeting 输入控件

- **WHEN** 运营人员打开 campaign 编辑表单
- **THEN** 表单 MUST 含 "开场白文案" 字段；控件类型 SHALL 是 textarea（推荐 3 行
  高度）；MUST 含 placeholder "留空则由 LLM 生成开场白" 提示留空行为；视觉风格
  MUST 跟 `STYLE_GUIDE.md` 一致（label / textarea 间距 / token 同其他字段）

#### Scenario: 保存空文案等价 NULL

- **WHEN** 运营人员把 greeting 字段留空 / 删空后保存
- **THEN** isales-web 在提交到 isales-api 前 SHOULD 把空字符串 normalize 为 NULL
  （或者依赖后端 isales-api 把空串归为 NULL）；最终 PG `campaign.greeting` 字段
  MUST 是 NULL 而非空串，让 engine 走 `generate_greeting` LLM 路径

#### Scenario: 保存非空文案立即影响下次 dial

- **WHEN** 运营人员保存 greeting 字段为非空文案
- **THEN** PG `campaign.greeting` 字段 MUST 是该字面文本；isales-engine 下次该
  campaign 的 dial 触发 `load_runtime_config` 时 MUST 直接读到新文案；engine MUST
  跳过 LLM 直接 TTS 该文案；MUST NOT 需要 engine 重启或 cache invalidation

#### Scenario: v1 不支持模板变量

- **WHEN** 运营人员在 greeting 字段写 `${lead_name}` 等占位符字面
- **THEN** isales-web SHALL NOT 警告或拒绝保存；isales-engine SHALL 把占位符字面
  字符串直接送 TTS；v1 SHALL NOT 解析任何 `${var}` 模板变量。模板变量支持留待
  future change

#### Scenario: greeting 字段与 ai-pipeline 既有 Requirement 协同

- **WHEN** Campaign 配置了非空 greeting
- **THEN** engine 行为 MUST 跟 `ai-pipeline § Requirement: 开场白不走管线 §
  Scenario: 固定模板开场白` 一致（直接 TTS 播放 greeting，不调任何 LLM）；本
  Requirement MUST NOT 改变开场白入 dialog_history 的行为（仍按 `ai-pipeline §
  Scenario: 开场白记入对话历史` 处理）

### Requirement: 工具配置界面（ToolsTab）

campaign 配置页 SHALL 提供工具配置入口（ToolsTab），让用户定义 `hangup` / `transfer` 工具及其 alias，供路由规则的 tool 动作引用。工具配置 SHALL 映射到 `campaign.tools` JSONB（schema 见 data-model spec）。

#### Scenario: 配置挂断工具

- **WHEN** 用户在 ToolsTab 添加一个 `hangup` 工具
- **THEN** 界面 SHALL 提供可选 `closing_phrase`（挂断前单句话术）+ `interrupt` 选项，保存后落 `campaign.tools[<alias>] = {type: hangup, ...}`

#### Scenario: 配置转人工工具

- **WHEN** 用户在 ToolsTab 添加一个 `transfer` 工具
- **THEN** 界面 SHALL 仅需 alias（衔接话术复用既有 `campaign.transfer_phrases` 单一来源，ToolsTab MUST NOT 提供第二套话术输入），保存后落 `campaign.tools[<alias>] = {type: transfer}`

#### Scenario: 工具 alias 唯一性

- **WHEN** 用户添加重复 alias 的工具
- **THEN** 界面 SHALL 阻止保存并提示 alias 重复（对应后端 `422 tool_alias_duplicate`）

### Requirement: persona 角色配置（role kind）

角色配置界面 SHALL 支持 `kind=persona` 角色（label 必填），与 main / referee / restructure / extractor 并列。persona 用于 eager 多人设推测对话（见 ai-pipeline spec）。

#### Scenario: 添加 persona 角色需填 label

- **WHEN** 用户添加一个 persona 角色
- **THEN** 界面 MUST 要求非空 label（同 campaign 内唯一），保存后落 `kind=persona` role_config；删除被路由规则引用的 persona 时 SHALL 提示先改规则（对应后端 delete-guard）

#### Scenario: persona 数量提示 cap

- **WHEN** 用户启用的对话路由总数（main + persona）超过 `persona_fanout_cap`（clamp [1,3]）
- **THEN** 界面 SHALL 提示推测并发上限（含 main 至多 3 条）并阻止超额启用（vendor 对取消的 token 计费）

### Requirement: 顶级信息架构 — 客户工作流五入口 + 模型厂商配置 + 更多折叠区

`isales-web` 管理后台 SHALL 以**单一角色的外呼工作流**组织顶层导航，不再区分运营/客户。顶部 sticky header SHALL 提供胶囊式分段控件，包含**四个主入口**（场景 / 线索 / 外呼 / 数据看板）+ **一个圆形配置按钮**（模型厂商）+ **一个「更多/设置」折叠入口**（承载低频 view）。"场景"SHALL 位于主入口序列最左，作为工作流的起点（建场景 → 灌线索 → 外呼 → 看板）。原「预约」主入口已随 change `admin-prune-vestigial-features` 删除（预约功能整体下线）。

per-campaign 的外呼策略配置不再是独立顶级入口，已并入 campaign 详情页（见 Requirement「per-campaign 外呼策略配置」）；"模型厂商"作为平台级全局凭据保留为圆形配置按钮；低频运营 view 收入「更多/设置」折叠区。SHALL NOT 存在独立的「运营管理」顶级入口或 `/operations` 落地页。

#### Scenario: 顶部导航的固定结构

- **WHEN** 用户登录后进入任意 `/` 下的子路由
- **THEN** 页面顶部 SHALL 显示固定（sticky）导航栏，左侧 logo + 标题，中间胶囊容器中 SHALL 包含四个文本+图标按钮 `[场景｜线索｜外呼｜数据看板]`，右侧 SHALL 包含一个圆形配置按钮（模型厂商）与一个「更多/设置」入口；MUST NOT 出现「运营管理」入口；MUST NOT 出现「预约」主入口

#### Scenario: 更多折叠区展开低频 view

- **WHEN** 用户打开「更多/设置」入口
- **THEN** SHALL 列出低频但可用的 view（通话监控 / 节假日 / 设备在线状态），点击任一项 SHALL 进入对应 view；MUST NOT 列出「音色目录」或「转人工任务」（两者均已删除）；视觉语言 SHALL 沿用客户面设计 token（`--isales-*`），MUST NOT 新造独立视觉系统

#### Scenario: 当前激活态视觉反馈

- **WHEN** 用户切换到任一主入口或配置入口
- **THEN** 被选中的按钮 SHALL 显示白色背景 + 主色文字 + 微阴影；其余按钮 SHALL 显示灰色文字、透明背景

#### Scenario: 移动端折叠

- **WHEN** 视口宽度 < 768px
- **THEN** 中间业务导航 SHALL 隐藏，配置入口与「更多/设置」入口 SHALL 保留可见

### Requirement: 场景打断规则可组合编辑

场景（campaign）配置 SHALL 在「打断配置」卡片（原标题「打断保护」）下提供 barge-in 判定的**两段互斥模式切换**「高级设置 ∣ 非高级设置」。当前模式 SHALL 由后端 `campaign.interruption_rules` 是否为 NULL 派生：NULL = 非高级（basic），非 NULL = 高级（advanced）；两模式 MUST NOT 同时生效（同一时刻只渲染其一的编辑区）。切到高级 MUST 用当前非高级字段合成初始规则树灌入编辑器（令 `interruption_rules` 非 NULL）；切回非高级 MUST 把 `interruption_rules` 清回 NULL。

- **非高级设置** 模式 SHALL 暴露三个标量字段：打断白名单（写 `interruption_whitelist`）、最小打断时长（写 `interruption_min_duration_ms`）、**最小打断字数**（写 `interruption_min_chars`，整数 ≥ 1，默认 2）。此模式下 `interruption_rules` 保持 NULL，引擎走 legacy 标量列合成默认树。
- **高级设置** 模式 SHALL 展示可组合规则树编辑器，支持组合节点 `and` / `or` / `not` 与叶子节点 `keyword`（含 `match` = 子串/精确 + 词集）/ `length` / `duration` / `regex` / `split_by_delimiter` / `none`，并 SHALL 以递归方式支持任意嵌套，写入 `campaign.interruption_rules`。保存前规则树随 campaign 提交，由 isales-api 校验（结构合法性 + 深度/节点上限 + regex pattern 长度上限）；校验失败前端 MUST 就地提示。
- **最大连续打断** 与 **连续打断策略** SHALL 作为**与模式无关**的字段，渲染在模式切换器**下方**，两种模式下均常显可编辑。

规则树文案与默认值 MUST 用客户能理解的语言呈现（对齐 STYLE_GUIDE，不直接暴露引擎内部字段名 —— 组合用「且/或/非」、叶子用「关键词/长度/时长/正则/分隔符」表述）。

#### Scenario: 非高级模式配置三个标量字段

- **WHEN** 管理员在「非高级设置」模式编辑 打断白名单 / 最小打断时长 / 最小打断字数 并保存
- **THEN** 三字段 MUST 随 campaign PATCH 分别写入 `interruption_whitelist` / `interruption_min_duration_ms` / `interruption_min_chars`，`interruption_rules` MUST 保持 NULL

#### Scenario: 切到高级模式播种初始树

- **WHEN** 管理员从「非高级设置」切到「高级设置」
- **THEN** UI MUST 用当前白名单 + 最小打断时长 + 最小打断字数生成初始树 `AND( NOT keyword(exact, 白名单), length(≥最小打断字数), duration(≥最小时长) )`（白名单为空时省略 keyword 子节点，与引擎 `default_rule` 同公式）灌入编辑器，令 `interruption_rules` 非 NULL；此时尚未保存，管理员可继续增删改

#### Scenario: 切回非高级模式清空规则树

- **WHEN** 管理员从「高级设置」切回「非高级设置」
- **THEN** UI MUST 把 `interruption_rules` 清回 NULL（保存后引擎回到由 legacy 标量列合成默认树的语义），MUST NOT 残留半棵树；非高级三个标量字段重新可编辑

#### Scenario: 两模式互斥不并存

- **WHEN** 渲染打断配置卡
- **THEN** 模式切换器 MUST 反映 `interruption_rules == null` 的当前态，且 MUST NOT 同时展示非高级标量编辑区与高级规则树编辑区

#### Scenario: 管理员组合配置打断规则并保存

- **WHEN** 管理员在「高级设置」模式用 and/or/not + 叶子节点搭出一棵打断规则树并保存
- **THEN** 前端 MUST 把规则树随 campaign 提交，校验通过后写入 `campaign.interruption_rules`；校验失败（422 `interruption_rule_invalid`）MUST 就地提示具体错误（非法 type / 超深 / regex 过长），MUST NOT 写入坏配置

#### Scenario: 切换节点类型重建为该类型默认形状

- **WHEN** 管理员把某个规则节点的类型从一种切到另一种（如 关键词 → 且）
- **THEN** 该节点 MUST 重建为新类型的合法默认形状（如「且」默认带一个子规则、「关键词」默认空词集 + 包含模式），MUST NOT 残留旧类型的字段产生非法形状

#### Scenario: 连续打断字段模式无关常显

- **WHEN** 打断配置卡处于任一模式（高级 / 非高级）
- **THEN** 最大连续打断 与 连续打断策略 字段 MUST 渲染在模式切换器下方并可编辑

### Requirement: main 角色卡单条锁定

campaign 配置页的 AI 角色编辑区中，`kind=main` 的角色卡 SHALL 被特殊化为「单条、必有、锁定」：MUST NOT 提供 enable/disable 开关（main 恒为启用）、MUST NOT 提供删除入口、MUST NOT 提供新增第二个 main 的入口、`name`/`label` 字段对 main SHALL 只读或隐藏（main 不进 `routing_rules`，label 对其冗余）。对 `kind=main`，本约束 SHALL 覆盖 §「三 LLM prompt 编辑（per-campaign）」中对 main/referee/extractor 三角色**同构**（均提供 name + enable 开关 + 增删）的泛化处理——更具体者优先。`kind ∈ {referee, extractor}` 的角色卡行为 MUST NOT 受本约束影响（维持可命名/可禁用/可增删）。

理由：data-model SHALL 保证 `kind=main` 每 campaign 恰好 1 行且 mandatory（引擎流式回复唯一驱动，`_first(RoleKind.MAIN)`）；禁用 / 删除 / 新增第二个 main 都会破坏该不变量或使 pipeline 失去主回复流。

#### Scenario: main 卡无禁用 / 删除 / 新增入口

- **WHEN** 用户打开 campaign 详情页的 AI 角色编辑区
- **THEN** main 角色卡 MUST NOT 渲染 enable/disable 开关、删除按钮、或"新增 main"入口
- **AND** referee / extractor 角色卡 SHALL 继续渲染各自的 enable 开关与增删入口

#### Scenario: main 卡名字字段锁定

- **WHEN** 用户查看或编辑 main 角色卡
- **THEN** `name`/`label` 字段 SHALL 只读或隐藏，MUST NOT 允许用户改写
- **AND** 已落库的 main `role_config.name` 历史值 SHALL 保留（仅前端不可编辑，MUST NOT 触发删除或清空）

#### Scenario: 不可创建第二个 main

- **WHEN** campaign 已存在一个 `kind=main` role_config
- **THEN** UI MUST NOT 提供任何创建第二个 `kind=main` 的路径（无新增按钮、无"复制 main"动作）

### Requirement: persona 推测并发上限（persona_fanout_cap）配置控件

campaign 的 persona 配置卡 SHALL 在卡头提供一个**功能开关**作为 `persona_fanout_cap` 的主控件——该开关是**真实启用/关闭多人设推测**的功能开关，而非仅控制页面展开/收起的纯前端折叠。开关切到「关」SHALL 写 `persona_fanout_cap=1`（仅 main、无推测 fan-out、无取消计费）；切到「开」SHALL 写 `persona_fanout_cap≥2`（从 1 切开时默认置 2）。卡体的展开/收起 SHALL 跟随该开关（开=展开、关=收起）。

开关为「开」时，persona 卡卡体 SHALL 提供「人设并发上限」数字控件（取值 clamp 到 [2,3]，定义每轮并行推测路由总数（含 main）的上限）；该并发上限数字控件 SHALL NOT 再出现在「门控路由 / 多流路由」配置区（已迁入 persona 卡）。控件值 SHALL 通过 campaign PATCH 持久化（后端 `CampaignUpdate.persona_fanout_cap` 已暴露），MUST NOT 仅存于浏览器 localStorage，MUST NOT 仅作纯前端展开态而不落库。

实现 SHALL 复用 `persona_fanout_cap` 作为开/关的唯一承载（`1`=关、`2/3`=开），MUST NOT 为此另引入独立的 `persona_enabled` 布尔字段（避免 `cap=1` 与 `enabled=false` 两处可表达"关"的冗余状态）。

#### Scenario: 开关关闭即关闭功能并落库 cap=1

- **WHEN** 用户在 persona 卡把卡头功能开关切到「关」并保存
- **THEN** UI SHALL 通过 campaign PATCH 写入 `persona_fanout_cap=1`，卡体 SHALL 收起
- **AND** 引擎据此每轮仅起 main、无推测 fan-out、无取消计费

#### Scenario: 开关开启即启用功能并落库 cap≥2

- **WHEN** 用户把 persona 卡卡头功能开关从「关」切到「开」
- **THEN** UI SHALL 把 `persona_fanout_cap` 置为 2（若当前 <2，否则保留现值 2/3），卡体 SHALL 展开露出「人设并发上限」(2/3) 控件与人设列表
- **AND** 保存后 SHALL 通过 campaign PATCH 持久化该值

#### Scenario: 卡内并发上限取值边界

- **WHEN** 功能开关为「开」，用户调「人设并发上限」数字控件
- **THEN** 控件取值 SHALL clamp 到 [2,3]，MUST NOT 提交越界值
- **AND** 「门控路由 / 多流路由」配置区 MUST NOT 再渲染该并发上限控件

#### Scenario: 重新加载回显开关与上限

- **WHEN** 用户重新加载 campaign
- **THEN** `persona_fanout_cap≥2` 的 campaign：persona 卡功能开关 SHALL 回显为「开」、卡体展开、并发上限控件 SHALL 显示持久化后的值
- **AND** `persona_fanout_cap=1` 的 campaign：功能开关 SHALL 回显为「关」、卡体收起

### Requirement: persona 列表卡删除前置校验

campaign「多流路由」配置区的 persona 列表 SHALL 在删除某条 persona 前做客户端预检：若当前已加载的 `routing_rules` 中存在 route action 的目标为该 persona 的 `label`，UI SHALL 提示用户"先在路由规则中移除对该人设的引用"并阻止删除，MUST NOT 直接发起删除请求。若客户端预检漏过、后端返回 422 `routing_rule_unknown_persona`，UI SHALL 将其翻译为同一句可读提示，MUST NOT 向用户暴露裸错误码。

#### Scenario: 删除被路由规则引用的 persona 被拦截

- **WHEN** 用户删除一条 `label` 仍被某 `routing_rules` route action 引用的 persona
- **THEN** UI SHALL 提示"先在路由规则中移除对该人设的引用"并保留该 persona，MUST NOT 删除

#### Scenario: 删除未被引用的 persona 成功

- **WHEN** 用户删除一条无任何 `routing_rules` route action 引用的 persona
- **THEN** UI SHALL 调用 role_config 删除端点移除该 `kind=persona` 行并从列表移除

