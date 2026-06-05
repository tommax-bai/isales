## Purpose

定义 AI 三层管线的输入合约：每次调用 LLM 时 prompt 如何组装、对话历史如何注入、跟进上下文如何添加、收尾期间如何切换。本规范是 ai-pipeline 的配套规范——管线决定"调几次、谁审谁选"，本规范决定"每次调用喂什么"。
## Requirements
### Requirement: Prompt 由 Campaign 完全自定义

所有 LLM 的 prompt 内容 SHALL 由 Campaign 完全控制，系统 MUST NOT 提供"统一 referee 规则"或"统一 extractor prompt"。系统 SHALL 仅提供工具与模板（v2 Web UI 可视化）。三类 LLM（main / referee / extractor）的 prompt MUST 各自独立。

#### Scenario: main / referee / extractor 全部自定义

- **WHEN** Campaign 创建者编辑 LLM prompt
- **THEN** main LLM、referee LLM、extractor LLM 三类 prompt MUST 全部由 Campaign 自由编写；系统 MUST NOT 强加统一前缀或后缀（除收尾追加段落，详见下文）

#### Scenario: campaign 只配置 1 个 main role

- **WHEN** Campaign 配置 role
- **THEN** main role MUST 恰好 1 个；referee MUST 恰好 1 个；extractor MUST 恰好 1 个（不再有 N 个 role / M 个 judge 的并行配置）

### Requirement: Prompt 三段式组装

每次调用 main LLM 时 engine SHALL 按以下结构组装：system message + 单条 user message。

#### Scenario: System message 内容

- **WHEN** 组装 main LLM 的 system message
- **THEN** 内容 MUST = 角色身份 + 目标定义 + **纯文本输出约束**（详见 § "main system prompt 内容规范"）；MAY 在末尾追加收尾指令（仅 WRAPPING_UP 期间）

#### Scenario: User message 拼接结构

- **WHEN** 组装 main LLM 的 user message
- **THEN** 单条 user message 中 MUST 顺序包含：
  1. 【上次通话纪要】（仅跟进时存在）
  2. 【线索信息】name, phone, custom_data 等
  3. 【对话】整通对话拼成文本，AI 与用户发言用 `AI:` / `用户:` 前缀区分，最后一行以 `AI:` 结尾

#### Scenario: 不使用标准 chat multi-turn

- **WHEN** 调用 main LLM Provider
- **THEN** engine MUST 把整通对话作为单条 user message 文本传入；MUST NOT 拆成多条 message 调用 chat completion 接口

### Requirement: 对话过长不做截断

v1 SHALL 不做对话历史的截断或摘要，依赖 LLM 长上下文能力。每个 Provider 接入时 MUST 记录 token 用量并接入监控告警。

#### Scenario: 长通话依赖长上下文

- **WHEN** 通话进行 30 轮以上
- **THEN** engine MUST 仍把全部历史拼入 user message；MUST NOT 自动截断或调用摘要 LLM

#### Scenario: token 用量监控

- **WHEN** Provider 返回 token 用量信息
- **THEN** engine SHALL 记录到 pipeline_trace；超阈值 MUST 触发告警（避免成本失控）

### Requirement: System Prompt 内容规范

main LLM system prompt 由 Campaign 编写。系统 SHALL 提供以下结构作为推荐模板（isales-web 模板复用）；用户 MUST 能完全覆写：

```
你是 {{角色身份描述}}。

【目标】
{{自由文本描述本次外呼的核心目标}}

【话术规范】
- {{风格要求}}
- {{合规要求}}

【输出格式】
你的输出必须遵循：
1. 只输出你要对客户说的话，不要任何解释 / 元信息 / 引号包裹
2. 不要使用 markdown 标题 / 加粗 / 列表
3. 不要使用 emoji / 表情符号
4. 不要输出 JSON / 代码块
5. 如果有多句，用句号 / 问号 / 感叹号自然分隔
6. 单句长度控制在 30 字以内（便于 TTS 自然停顿）
```

**重要变化**: 与本 change 之前对比，main LLM **不再输出 JSON**（删除 `{reply, goal_achieved, goal_type, extracted}` schema 段）。结构化字段由 referee（goal_achieved + goal_type）+ post-call extractor（extracted）承担。

#### Scenario: 系统模板可覆写

- **WHEN** Campaign 创建者使用模板
- **THEN** 模板各段 SHALL 可独立编辑或删除

#### Scenario: 输出格式约束必须保留

- **WHEN** Campaign 创建者编辑 main prompt
- **THEN** 即便完全覆写，系统 SHOULD 在 prompt 编辑器 UI 提示"必须包含纯文本输出约束"；engine 自身 MUST NOT 强制注入约束（保 Campaign 自由度，按 § "Prompt 由 Campaign 完全自定义"）

### Requirement: 收尾期间在 system prompt 末尾追加指令

WRAPPING_UP 期间 engine SHALL 在 main system prompt 末尾追加预定义指令（如"通话即将结束，请用一句话总结并道别"），追加位置 MUST 是最末。

#### Scenario: WRAPPING_UP 进入即追加

- **WHEN** session 进入 WRAPPING_UP
- **THEN** 该轮及之后 PROCESSING 调 main LLM 时，system prompt 末尾 MUST 含追加指令

#### Scenario: prompt_versions 快照标记

- **WHEN** WRAPPING_UP 期间 main LLM 调用产生 pipeline_trace
- **THEN** `call_record.prompt_versions.wrap_up_appended` MUST 标 `true`

### Requirement: 跟进通话的 prompt 增强

跟进通话调用角色 LLM 时 engine SHALL 在 system prompt 末尾追加跟进上下文段落（紧跟收尾指令之前）。上次通话摘要 SHALL 由 scheduler 在 dial 队列消息中携带，engine MUST NOT 直接查 DB。

#### Scenario: 跟进段落格式

- **WHEN** 通话是跟进通话（is_follow_up=true, follow_up_count=N）
- **THEN** system prompt 末尾追加：
  ```
  【跟进上下文】
  这是对该用户的第 N 次跟进。上次通话结束于 {timestamp}。
  请根据下面的【上次通话纪要】调整开场和后续话术，避免重复内容。
  ```

#### Scenario: 历史摘要由 scheduler 注入到 user message

- **WHEN** scheduler 派发跟进通话
- **THEN** dial 消息 MUST 携带 `last_call_summary` 字段；engine SHALL 把该摘要放入 user message 的「上次通话纪要」段，MUST NOT 自行查 call_summary 表

### Requirement: Prompt 版本管理

`prompt_version` 表 SHALL 存储所有 prompt 历史；`role_config.current_prompt_version_id` 指向当前生效版本；通话开始时 engine MUST 把当时各 LLM 的 prompt_version_id 一次性写入 `call_record.prompt_versions` 字段（**snapshot schema 改为 main / referee / extractor 三 key**）。

#### Scenario: 编辑 prompt 自动建新版本

- **WHEN** 用户在 isales-web 编辑某 role_config 的 prompt
- **THEN** 系统 SHALL 创建新 `prompt_version` 记录（旧版本保留只读）；用户决定启用新版本时更新 `role_config.current_prompt_version_id`

#### Scenario: 通话开始时写入快照

- **WHEN** call_session 初始化
- **THEN** engine MUST 把当前相关 prompt_version_id 写入 `call_record.prompt_versions`：
  ```json
  {
    "main_llm": {"role_config_id": 1, "prompt_version_id": 5},
    "referee_llm": {"role_config_id": 2, "prompt_version_id": 8},
    "extractor_llm": {"role_config_id": 3, "prompt_version_id": 12},
    "wrap_up_appended": false
  }
  ```

#### Scenario: prompt_version.scope_type 枚举

- **WHEN** 创建 prompt_version 记录
- **THEN** `scope_type` SHALL ∈ `{"main", "referee", "extractor"}`；旧值 `"role"` / `"judge"` / `"polish"` 在 alembic migration 中删除对应记录（详见 data-model spec）

#### Scenario: 调试回放精准复现

- **WHEN** 调试历史通话
- **THEN** 通过 prompt_version_id 取到当时的原文，可精准复现调用时使用的 prompt

### Requirement: referee prompt 内容规范

每个 `kind=referee` 的 role_config SHALL 拥有独立的 system prompt，prompt 内 MUST 显式定义该 referee 输出的闭集分类枚举（category 取值集合）及每个取值的语义。不同 referee 的枚举集合互不相关，engine 不解释其语义。referee prompt MUST 约束 LLM 输出严格 JSON `{category, confidence}` 且 `category` ∈ 该 prompt 定义的闭集，MUST 指示「只输出枚举集合内的一个 category，不得自创取值，不输出解释/markdown」。referee prompt 输入变量遵循既有约定（`{{user_last_utterance}}` + `{{recent_dialog_history}}`，渲染规则见下）。

#### Scenario: 单职责 referee prompt

- **WHEN** campaign 配置一个「拒绝识别」referee
- **THEN** 其 prompt SHALL 定义闭集如 `OFFENSIVE / REJECT / OPERATOR / NEUTRAL` 并逐项说明语义，要求 LLM 只输出其一
- **AND** 另一个「意图有效性」referee 的 prompt 独立定义 `POSITIVE / NEGATIVE`，两者枚举不共享

#### Scenario: referee prompt 强制闭集输出

- **WHEN** referee LLM 被调用
- **THEN** prompt MUST 指示「只输出枚举集合内的一个 category，不得自创取值，不输出解释/markdown」

#### Scenario: prompt 输入填充

- **WHEN** engine 调 referee LLM
- **THEN** engine MUST 替换 `{{user_last_utterance}}` 为最新 ASR 文本；MUST 替换 `{{recent_dialog_history}}` 为最近 ≤ 3 轮（少于 3 轮取全部）按 `用户：xxx / AI：xxx` 格式拼接

#### Scenario: dialog_history 为空

- **WHEN** session 处于首轮（dialog_history 为空 / 只有 greeting）
- **THEN** `{{recent_dialog_history}}` MUST 渲染为 `（首轮对话，无历史）` 占位字符串；MUST NOT 留空

### Requirement: extractor prompt 内容规范

extractor LLM 在 worker 服务中跑（post-call 异步），输入 = 完整 transcript_snapshot；prompt SHALL 指定要抽取的字段 schema（Campaign 自定义）。

```
你是销售通话信息抽取助手。基于完整通话记录，抽取以下字段：

【字段定义】
{{campaign 自定义字段 schema，如：}}
- customer_name (str): 客户姓名
- intent (enum): "interested" | "considering" | "declined"
- callback_time (datetime str): 客户同意的回访时间，如未约定则 null
- ...

【输入】
{{transcript}}

【输出 JSON】
{
  "customer_name": ...,
  "intent": ...,
  "callback_time": ...
}

只输出 JSON，所有字段都要给（无信息时给 null）。
```

#### Scenario: 字段 schema Campaign 自定义

- **WHEN** Campaign 创建者编辑 extractor prompt
- **THEN** 字段定义段 MUST 由 Campaign 完全自由编写；系统 MUST NOT 强制最小字段集（不同业务字段诉求差异大）

#### Scenario: 输入 transcript 拼接格式

- **WHEN** engine LPUSH extract 任务
- **THEN** `transcript_snapshot` payload MUST 是 dialog_history 的序列化（每个 entry `{role, text, ts_ms}`），由 worker 端按 `用户：xxx / AI：xxx` 渲染入 extractor prompt 的 `{{transcript}}` 占位

### Requirement: restructure / rewrite prompt 内容规范

`kind=restructure` 的 role_config prompt SHALL 是「对话包装/重写」指令：把输入文本用更口语化的方式重新组织、可调整语序与用词、MUST NOT 改变原意与目的、SHOULD 在开头加自然过渡衔接词、MUST NOT 输出 markdown/emoji/解释。restructure prompt 的输入是 InterruptText（单条文本），prompt MUST NOT 假设能看到对话历史。

#### Scenario: restructure prompt 重组而不改意

- **WHEN** restructure LLM 收到 InterruptText（上一句 AI 要点或被打断残留）
- **THEN** prompt SHALL 指示「用口语化方式重新表达这句话，可换语序/用词、开头加过渡词，但不得更改含义或目的，直接输出结果」

#### Scenario: restructure prompt 不依赖历史

- **WHEN** 编写 restructure prompt
- **THEN** prompt MUST NOT 引用「对话历史」「用户上一句」等上下文变量，因 engine 只喂单条 InterruptText

## Data Schema

| 字段 / 表 | 用途 |
|---|---|
| `prompt_version` | id, scope_type (`role` / `judge` / `polish`), scope_id, content, created_at, created_by, is_active |
| `role_config.current_prompt_version_id` | FK 指向当前生效版本 |
| `call_record.prompt_versions` (JSONB) | 通话开始时的 prompt 版本快照 |
| `role_config.model`, `temperature`, `top_p`, `ext_params` (JSONB) | LLM 调用参数 |
