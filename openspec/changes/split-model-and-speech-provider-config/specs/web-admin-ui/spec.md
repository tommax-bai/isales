## MODIFIED Requirements

### Requirement: 已 spec 能力的 UI 暴露

`isales-web` SHALL 在 view 中暴露以下 backend 已 spec 的能力（本 change 把 prompt 配置从 4-tier 改为 **3-tier**）：

- 三 LLM prompt 配置（`role-prompt`、`filler`、`goal-achievement`、`ai-pipeline`）— 在 **campaign 详情 view** 中按 3 个 tier（**main 对话主 LLM / referee 决策旁路 LLM / extractor 信息抽取 LLM**）分组，per-campaign 增删改 + enable switch + temperature/topP 滑杆 + provider/model 选择器。**删除原 4-tier 中的 judge / polish 编辑区**。
- 可通话时段配置（`time-window`）— 在 **campaign 详情 view** 中以多个时段卡片形式列出，每段含开始时间、结束时间、周一至周日 7 个 checkbox，写入该 `campaign.time_windows`
- AI 服务商凭据管理（`provider-abc` + `provider-credential`）— 后台 SHALL 按真实产品线拆成**两块配置**：**「模型配置」**（LLM provider，火山方舟 / 豆包大模型 `volcengine` + 阿里通义 DashScope，每卡含该 provider 自己的 API key（火山方舟为 ark key）+ endpoint + 默认 model 字段）与**「语音服务配置」**（ASR/TTS provider，豆包语音 `volcengine_speech`，含 app_key + app_token + tts_resource_id）。各卡只承载自己产品线的密钥，MUST NOT 跨 LLM/语音复用同一组输入框；**凭据 SHALL 通过 `/api/provider-credentials` admin API 直接落库**（`provider_credential` 表，Fernet 加密；MUST NOT 用 localStorage 兜底）。UI 仅显示 mask preview，改 key = 整段替换。ASR/TTS provider 为引擎进程级全局，非 per-campaign
- ASR 完整对话内容（`transcript`）— 在外呼记录 view 的每条记录上以可折叠面板展示，AI 与客户消息用左右气泡区分
- 目标达成评分（`goal-achievement`）— 在外呼记录卡片中展示评分、客户意向、是否成功预约、已覆盖的关键要点列表。**`extracted` 字段从 `call_summary.extracted_fields` 改读 `call_record.extracted`**（post-call extractor 异步写入）

#### Scenario: 模型配置与语音服务配置分卡

- **WHEN** 用户进入后台凭据管理
- **THEN** UI SHALL 呈现两块独立配置：「模型配置」列出 LLM provider 卡（`volcengine` 火山方舟 + `dashscope`），「语音服务配置」列出语音 provider 卡（`volcengine_speech` 豆包语音）
- **AND** 火山方舟 LLM 卡的 API key 字段 SHALL 对应 `provider_id='volcengine'` 的 `api_key`（ark key），豆包语音卡的 app_key/app_token/tts_resource_id SHALL 对应 `provider_id='volcengine_speech'`；二者 MUST NOT 共用同一输入框或写入同一 provider_id

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
- **THEN** 可选项 SHALL 对齐 `isales-engine` factory 实装的**真实** LLM provider（volcengine / dashscope），MUST NOT 列出引擎未对接的 provider
- **AND** `mock` 虽是 engine factory 合法 provider 名（测试 / dev 经 `ISALES_ENGINE_LLM_PROVIDER` env 配置）但 MUST NOT 在 UI 的 provider 选择器或「模型配置」凭据卡中暴露（它无需凭据、选中即把真活动配成假 LLM）
- **AND** main 用大模型（如 doubao-pro），referee 与 extractor MAY 推荐用便宜小模型（如 qwen-turbo / doubao-lite），编辑器 SHALL 在 model 选择器 hover 时显示"main 推荐 ⭐⭐⭐ / referee 推荐 ⭐ / extractor 推荐 ⭐"

#### Scenario: 模型厂商配置写入 DB

- **WHEN** 用户在「模型配置」或「语音服务配置」卡输入 / 修改 / 删除一个 provider 的 api_key / app_key / app_token / tts_resource_id / endpoint / default_model / enabled
- **THEN** UI SHALL 调用 `/api/provider-credentials` POST / DELETE 接口（按对应 provider_id：`volcengine` / `dashscope` / `volcengine_speech`）；后端 SHALL Fernet 加密后 upsert 行；UI MUST NOT 把任何 provider 密钥写入 localStorage

#### Scenario: API key 仅显示 mask preview

- **WHEN** 用户进入凭据卡看到已配置的 provider
- **THEN** API key / app_token 等敏感字段输入框 SHALL 显示 `<前 4 字符>********<后 4 字符>` 形式；MUST NOT 显示明文；改密钥 SHALL 整段替换

#### Scenario: 通话气泡显示

- **WHEN** 用户在外呼记录中点击"查看通话内容"
- **THEN** SHALL 展开可折叠区域，按 transcript 顺序逐条渲染气泡，AI 消息靠左、客户消息靠右，气泡上方 SHALL 显示角色标签
