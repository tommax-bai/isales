<!-- delta: web-admin-ui — rename referee 旁路→门控监管 (display only) + fix referee prompt editor hint to bare-category-token contract (no JSON/confidence); keep kind=referee/scope_type=referee/role_config literals verbatim -->

## MODIFIED Requirements

### Requirement: 已 spec 能力的 UI 暴露

`isales-web` SHALL 在 view 中暴露以下 backend 已 spec 的能力（本 change 把 prompt 配置从 4-tier 改为 **3-tier**）：

- 三 LLM prompt 配置（`role-prompt`、`filler`、`goal-achievement`、`ai-pipeline`）— 在 **campaign 详情 view** 中按 3 个 tier（**main 对话主 LLM / 门控监管 LLM（主路径门控、与 main 并行执行） / extractor 信息抽取 LLM**）分组，per-campaign 增删改 + enable switch + temperature/topP 滑杆 + provider/model 选择器。**删除原 4-tier 中的 judge / polish 编辑区**。
- 可通话时段配置（`time-window`）— 在 **campaign 详情 view** 中以多个时段卡片形式列出，每段含开始时间、结束时间、周一至周日 7 个 checkbox，写入该 `campaign.time_windows`
- AI 服务商凭据管理（`provider-abc` + `provider-credential`）— 在「模型厂商」view 中统一管理 LLM / ASR / TTS provider，按 provider 分卡片，含 API key 密码输入 + endpoint + 默认 model + enable switch + 状态徽标。**凭据 SHALL 通过 `/api/provider-credentials` admin API 直接落库**（`provider_credential` 表，Fernet 加密；MUST NOT 用 localStorage 兜底）。UI 仅显示 mask preview，改 key = 整段替换。volcengine 一套 app_key/token 同时供 LLM / ASR / TTS（凭据一体，故不为 ASR/TTS 单设 view）；ASR/TTS provider 为引擎进程级全局，非 per-campaign
- ASR 完整对话内容（`transcript`）— 在外呼记录 view 的每条记录上以可折叠面板展示，AI 与客户消息用左右气泡区分
- 目标达成评分（`goal-achievement`）— 在外呼记录卡片中展示评分、客户意向、是否成功预约、已覆盖的关键要点列表。**`extracted` 字段从 `call_summary.extracted_fields` 改读 `call_record.extracted`**（post-call extractor 异步写入）

#### Scenario: 三 LLM prompt 编辑（per-campaign）

- **WHEN** 用户在 campaign 详情 view 添加 / 编辑 main / 门控监管 / extractor 三个 LLM 之一
- **THEN** 表单 SHALL 提供 name / model provider / model name / temperature(0–2) / topP(0–1) / prompt 文本 / enable 开关；保存后 SHALL 通过 admin API 写入归属该 campaign 的 `role_config (kind=<main|referee|extractor>)` + `prompt_version (scope_type=<main|referee|extractor>)`
- **AND** UI MUST NOT 暴露 `judge` / `polish` 类型的 role_config 编辑入口

#### Scenario: main prompt 编辑器提示纯文本输出

- **WHEN** 用户在 campaign 详情 view 编辑 main role 的 prompt
- **THEN** 编辑器右侧 SHALL 显示提示卡片"main LLM 输出必须是纯文本，不要 JSON / markdown / emoji"；MUST NOT 强制注入约束段（保 Campaign 自由度，按 `role-prompt` § "Prompt 由 Campaign 完全自定义"）

#### Scenario: referee prompt 编辑器提示 JSON 输出

- **WHEN** 用户编辑 门控监管（role kind=referee）的 prompt
- **THEN** 编辑器 SHALL 显示提示"门控监管只输出一个分类词（category token），取值由本门控监管 prompt 自定义闭集枚举；门控路由按此 category 匹配，无命中默认放行 main —— 无 JSON、无 confidence、无标点"；编辑器 SHALL 提供"插入推荐模板"按钮（一键填入 § role-prompt § "门控监管 prompt 内容规范" 的模板）

#### Scenario: extractor prompt 编辑器提示字段 schema

- **WHEN** 用户编辑 extractor role 的 prompt
- **THEN** 编辑器 SHALL 显示提示"extractor 输出 JSON，字段 schema 自定义"；MAY 提供 schema 字段表（field_name + type + nullable）辅助生成 prompt 段

#### Scenario: provider 选项对齐引擎实装

- **WHEN** 用户在 prompt 配置或 provider 配置中选择 model provider
- **THEN** 可选项 SHALL 对齐 `isales-engine` factory 实装的 provider（LLM：volcengine / openai / mock），MUST NOT 列出引擎未对接的 provider
- **AND** main 用大模型（如 doubao-pro / gpt-4o），门控监管 与 extractor MAY 推荐用便宜小模型（如 qwen-turbo / gpt-4o-mini / doubao-lite），编辑器 SHALL 在 model 选择器 hover 时显示"main 推荐 ⭐⭐⭐ / 门控监管 推荐 ⭐ / extractor 推荐 ⭐"

#### Scenario: 模型厂商配置写入 DB

- **WHEN** 用户在「模型厂商」view 输入 / 修改 / 删除一个 provider 的 api_key / app_key / app_token / endpoint / default_model / enabled
- **THEN** UI SHALL 调用 `/api/provider-credentials` POST / DELETE 接口；后端 SHALL Fernet 加密后 upsert 行；UI MUST NOT 把任何 provider 密钥写入 localStorage

#### Scenario: API key 仅显示 mask preview

- **WHEN** 用户进入「模型厂商」view 看到已配置的 provider 卡片
- **THEN** API key / app_token 等敏感字段输入框 SHALL 显示 `<前 4 字符>********<后 4 字符>` 形式；MUST NOT 显示明文；改密钥 SHALL 整段替换

#### Scenario: 通话气泡显示

- **WHEN** 用户在外呼记录中点击"查看通话内容"
- **THEN** SHALL 展开可折叠区域，按 transcript 顺序逐条渲染气泡，AI 消息靠左、客户消息靠右，气泡上方 SHALL 显示角色标签

### Requirement: per-campaign 外呼策略配置

外呼策略配置 SHALL 绑定到具体 campaign 并持久化到后端，不再是全局配置。campaign 详情 view SHALL 承载以下 per-campaign 配置：**3-tier 串行 LLM（main / 门控监管 / extractor）**、可拨时段、选用音色、**filler_enabled toggle 与 filler_delay_ms 触发延迟**。配置 SHALL 通过 admin API 持久化（`role_config` / `prompt_version` / `filler_set` / `filler_phrase` 按 campaign 写入；`campaign.time_windows` / `campaign.voice_id` / `campaign.filler_enabled` / `campaign.filler_delay_ms` 通过 campaign PATCH 写入），MUST NOT 仅存于浏览器 localStorage。

#### Scenario: 配置入口先选定 campaign

- **WHEN** 用户要编辑 AI 外呼策略
- **THEN** SHALL 先进入某个 campaign 的详情 view，配置区操作的对象 SHALL 明确归属该 campaign

#### Scenario: 三 LLM prompt 编辑（per-campaign）

- **WHEN** 用户在 campaign 详情的 AI 外呼配置区编辑 main / 门控监管 / extractor 之一
- **THEN** 表单 SHALL 提供 name / model provider / model name / temperature(0–2) / topP(0–1) / prompt 文本 / enable 开关；保存后 SHALL 通过 admin API 写入归属该 `campaign_id` 的 `role_config` + `prompt_version`，kind / scope_type ∈ `{main, referee, extractor}`

#### Scenario: filler_enabled toggle

- **WHEN** 用户在 campaign 详情 view 切换 filler 启用开关
- **THEN** UI SHALL 调 campaign PATCH API 写入 `campaign.filler_enabled` 字段（bool, default false）；切到 false 时同 page 隐藏 filler_set / filler_phrase 编辑区
- **AND** UI SHALL 在 filler 区上方显示提示"streaming 主链路首音频 ~500ms，filler 仅在用慢模型时建议启用"

#### Scenario: filler_delay_ms 触发延迟

- **WHEN** 用户在 campaign 详情 view 开启 filler 后编辑触发延迟
- **THEN** UI SHALL 展示 `filler_delay_ms` 数值输入（仅 `filler_enabled=true` 时可见），调 campaign PATCH API 写入 `campaign.filler_delay_ms`（int，可空，留空表示 engine 默认 600ms）

#### Scenario: 时段与音色

- **WHEN** 用户在 campaign 详情编辑可拨时段或选用音色
- **THEN** 可拨时段 SHALL 写入该 `campaign.time_windows`；音色 SHALL 从全局音色库（`voice_model`）中选择并写入 `campaign.voice_id`

#### Scenario: 配置持久化替代 localStorage

- **WHEN** 用户保存某 campaign 的外呼策略后刷新页面
- **THEN** 配置 SHALL 从后端重新加载并保持一致

### Requirement: campaign 多流路由配置界面

campaign 配置页 SHALL 提供「多流路由」配置区，包含：① 主对话流（main，单条）；② 重组流（restructure，单条，可不配）；③ 门控监管列表（N 个 门控监管 LLM（主路径门控、与 main 并行执行），可增删）；④ 路由规则编辑器；⑤ **人设列表（N 个 persona，可增删，opt-in，cap ≤ 3）**；⑥ **工具配置（hangup / transfer，见 § "工具配置界面（ToolsTab）"）**。每个门控监管 SHALL 可编辑 label / model / prompt / 输出枚举语义说明（输出为闭集枚举里的一个 category 词，bare token，无 JSON、无 confidence）。路由规则编辑器 SHALL 让用户按顺序增删规则，每条规则可选「绑定哪个门控监管 → 匹配哪些 category → 执行什么 action」；action SHALL 支持 路由到角色(persona) / 工具(挂断·转人工) / 状态转移 / 切重组流，并可选 `then_state` 目标。

#### Scenario: 增删裁判

- **WHEN** 用户在 门控监管列表点「添加门控监管」
- **THEN** 界面 SHALL 新增一行可编辑 门控监管（label / model / prompt），保存后落 `kind=referee` role_config
- **AND** 删除某门控监管时 SHALL 校验无 routing_rules 仍引用其 label，否则提示先改规则

#### Scenario: 路由规则有序编辑

- **WHEN** 用户编辑路由规则
- **THEN** 界面 SHALL 以有序列表呈现规则、支持调整顺序（顺序即优先级），每条规则可选 门控监管（下拉其 label）+ 匹配 category（多选其枚举）+ action
- **AND** action 编辑器 SHALL 提供四类：① 状态转移（to + goal_type）② 切重组流（source）③ **路由到角色**（route → 下拉 persona label 或内置 closing/recovery/restructure）④ **工具**（tool → 下拉 hangup/transfer alias）；③④ 及①可选 `then_state` 下拉（LISTENING / WRAPPING_UP / ACTIVATING / TRANSFERRING / END）

#### Scenario: 切换 action 目标清空陈旧字段（修 422）

- **WHEN** 用户把某条规则的 action 目标从 `goal_achieved`（带 goal_type）切到其它目标（transfer / route / tool / restructure）
- **THEN** 界面 MUST 清空不再适用的 `goal_type`（及其它陈旧分支字段），使提交载荷只含当前 action 类型的合法字段；MUST NOT 残留 `goal_type` 导致后端 `422` 保存失败（cherry-forward 自 superseded `referee-hangup-action` 的已知 bug 修复）

#### Scenario: 配置重组流

- **WHEN** 用户启用重组流
- **THEN** 界面 SHALL 提供 restructure 的 model + prompt 编辑入口，并提示「输入为被打断残留或上一句要点，prompt 应写重写/包装指令」

#### Scenario: 单裁判向后兼容呈现

- **WHEN** 打开一个仅含单 门控监管（role kind=referee） + 默认规则的存量 campaign
- **THEN** 界面 SHALL 正常呈现该单门控监管与等价默认规则，用户 MAY 在此基础上加门控监管/规则，存量配置 MUST NOT 被破坏
