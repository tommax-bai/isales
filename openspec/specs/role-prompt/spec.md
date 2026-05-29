## Purpose

定义 AI 三层管线的输入合约：每次调用 LLM 时 prompt 如何组装、对话历史如何注入、跟进上下文如何添加、收尾期间如何切换。本规范是 ai-pipeline 的配套规范——管线决定"调几次、谁审谁选"，本规范决定"每次调用喂什么"。

## Requirements

### Requirement: Prompt 由 Campaign 完全自定义

所有 LLM 的 prompt 内容 SHALL 由 Campaign 完全控制，系统 MUST NOT 提供"统一裁判规则"或"统一润色 prompt"。系统 SHALL 仅提供工具与模板（v1 命令行 + v2 Web UI 可视化）。

#### Scenario: 角色 / 裁判 / 润色全部自定义

- **WHEN** Campaign 创建者编辑 LLM prompt
- **THEN** 角色 LLM、裁判 LLM、润色 LLM 三类 prompt MUST 全部由 Campaign 自由编写；系统 MUST NOT 强加统一前缀或后缀（除收尾追加段落，详见下文）

#### Scenario: 多角色 prompt 完全独立

- **WHEN** Campaign 配置 N 个角色
- **THEN** 每个角色的 prompt MUST 完全独立编写，**MUST NOT 共享 base prompt**（多样性是 PK 的本意）

### Requirement: Prompt 三段式组装

每次调用角色 LLM 时 engine SHALL 按以下结构组装：system message + 单条 user message。

#### Scenario: System message 内容

- **WHEN** 组装 system message
- **THEN** 内容 MUST = 角色身份 + 目标定义 + JSON 输出 schema；MAY 在末尾追加收尾指令（仅 WRAPPING_UP 期间）

#### Scenario: User message 拼接结构

- **WHEN** 组装 user message
- **THEN** 单条 user message 中 MUST 顺序包含：
  1. 【上次通话纪要】（仅跟进时存在）
  2. 【线索信息】name, phone, custom_data 等
  3. 【对话】整通对话拼成文本，AI 与用户发言用 `AI:` / `用户:` 前缀区分，最后一行以 `AI:` 结尾

#### Scenario: 不使用标准 chat multi-turn

- **WHEN** 调用 LLM Provider
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

System prompt 由 Campaign 编写。系统 SHALL 提供以下结构作为推荐模板（isales-web 模板复用）；用户 MUST 能完全覆写：

```
你是 {{角色身份描述}}。

【目标】
{{自由文本描述本次外呼的核心目标}}

【判定为达成的具体标准】
- {{标准 1}}
- {{标准 2}}

【可提取字段】
{{字段名}}：{{含义和格式要求}}

【输出格式】
你必须严格按照以下 JSON 格式输出（不要添加任何解释性文字）：
{
  "reply": "<要播给用户的话术>",
  "goal_achieved": <true 或 false>,
  "goal_type": "<达成的目标类型，未达成时为空字符串>",
  "extracted": { <本轮新提取到的结构化字段> }
}

【话术规范】
- {{风格要求}}
- {{合规要求}}
```

#### Scenario: 模板提供建议结构

- **WHEN** 用户在 isales-web 创建新角色
- **THEN** 系统 MAY 提供上述结构作为可编辑模板；用户 SHALL 可完全覆写

### Requirement: 收尾期间在 system prompt 末尾追加指令

WRAPPING_UP 状态下 engine MUST 在原 system prompt **末尾追加**收尾指令段落，原内容 MUST 保持不变。

#### Scenario: 收尾追加段落

- **WHEN** 进入 WRAPPING_UP 后调用角色 LLM
- **THEN** system prompt 在原内容末尾追加：
  ```
  ---
  【当前状态：收尾对话】
  目标已达成。请简短确认或告别后结束对话，不要再尝试推进新议题。
  ```

#### Scenario: prompt_versions 标记追加状态

- **WHEN** 通话开始时记录 prompt_versions 快照
- **THEN** 快照 MUST 包含 `wrap_up_appended: true/false`，便于 transcript 回放时区分

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

### Requirement: JSON Mode 强制策略（两步保护）

引擎 SHALL 优先使用 Provider 原生 JSON Mode；不支持的 Provider MUST 在 prompt 末尾贴 schema 描述并对响应做后处理。

#### Scenario: 原生 JSON Mode 优先

- **WHEN** Provider 支持 JSON Mode（OpenAI `response_format` / Claude tool use / 通义 / 豆包 / 智谱原生）
- **THEN** engine MUST 启用原生 JSON Mode；Provider ABC 的 `supports_json_mode` 返回 true

#### Scenario: 文本约束兜底

- **WHEN** Provider 不支持原生 JSON Mode
- **THEN** engine SHALL 在 system prompt 末尾贴 schema 描述；后处理顺序：① `json.loads` → ② 失败则正则提取 `{...}` 段重试 → ③ 再失败则降级（整段文本作为 reply，其他字段置空）

#### Scenario: 解析失败的处理

- **WHEN** 单角色 JSON 解析失败
- **THEN** 该候选 MUST 直接淘汰；engine 进入 ai-pipeline 的"全部裁判否决"路径仅当 N 个角色全部失败

### Requirement: Prompt 版本管理

`prompt_version` 表 SHALL 存储所有 prompt 历史；`role_config.current_prompt_version_id` 指向当前生效版本；通话开始时 engine MUST 把当时各 LLM 的 prompt_version_id 一次性写入 `call_record.prompt_versions` 字段。

#### Scenario: 编辑 prompt 自动建新版本

- **WHEN** 用户在 isales-web 编辑某 role_config 的 prompt
- **THEN** 系统 SHALL 创建新 `prompt_version` 记录（旧版本保留只读）；用户决定启用新版本时更新 `role_config.current_prompt_version_id`

#### Scenario: 通话开始时写入快照

- **WHEN** call_session 初始化
- **THEN** engine MUST 把当前所有相关 prompt_version_id 写入 `call_record.prompt_versions`：
  ```json
  {
    "role_llms": [{"role_config_id": 1, "prompt_version_id": 5}, ...],
    "judge_llms": [{"role_config_id": 7, "prompt_version_id": 12}, ...],
    "polish_llm": {"role_config_id": 9, "prompt_version_id": 3},
    "wrap_up_appended": false
  }
  ```

#### Scenario: 调试回放精准复现

- **WHEN** 调试历史通话
- **THEN** 通过 prompt_version_id 取到当时的原文，可精准复现调用时使用的 prompt

### Requirement: Judge 拿到对话上下文

engine 调用 judge LLM 时, user message MUST 包含两个 markdown section: 对话历史段
（`### 对话历史` 标题，按 `用户：xxx / AI：xxx` 格式）+ 候选回复段（`### 销售 AI
准备发给客户的候选回复` 标题）。本 Requirement MUST 仅约束 engine 这一侧 user message
拼装规则，SHALL NOT 约束 PG-stored judge prompt 文案（业务侧自定义）。本 Requirement
与已有 `JUDGE_OUTPUT_SCHEMA_SUFFIX` 机制正交——SUFFIX 仍 SHALL 追加到 system prompt
末尾强约束 JSON 输出。

#### Scenario: 标准多轮通话 N 轮对话历史

- **WHEN** judge 在第 N 轮（N≥2）评判 candidate, `session.dialog_history` 已含 N-1
  轮的 user / AI 发言
- **THEN** user message 历史段 MUST 渲染为 N-1 行（每行 `用户：xxx` 或 `AI：xxx`），
  按发言顺序排列；MUST NOT 包含尾部 `AI:` 提示行（judge 不是要说话的角色）；MUST
  使用全角冒号 `：` 跟 role 端 `_render_dialog` 风格一致

#### Scenario: greeting 后首次评判，对话历史为空

- **WHEN** judge 在首轮评判 candidate, `session.dialog_history` 为空（greeting 路径
  未将开场白追加到 `dialog_history`，或者其他空状态场景）
- **THEN** 历史段 MUST 渲染显式占位字符串 `（尚无对话历史，这是首轮回复）`；MUST NOT
  让历史段空白（避免 LLM 把"空"误读为信号缺失或 prompt corruption）；候选回复段 MUST
  正常渲染

#### Scenario: 用户/AI 前缀与角色风格

- **WHEN** engine 渲染对话历史段
- **THEN** 用户发言 MUST 用 `用户：` 前缀，AI 发言 MUST 用 `AI：` 前缀；MUST NOT
  使用英文 `user/assistant` 或别的中文标签；前缀与发言文本 MUST 用全角冒号 `：`
  分隔（跟 role 端 `_render_dialog` 风格一致）

#### Scenario: PG-stored judge prompt 文案不变

- **WHEN** Campaign 编辑者更新 `prompt_version` 表里 judge slot 的 prompt 内容
- **THEN** engine MUST 仍把 PG-stored 文案完整作为 system prompt 内容（追加
  `JUDGE_OUTPUT_SCHEMA_SUFFIX` 末尾）发给 LLM；本 Requirement MUST NOT 干涉 PG-stored
  judge prompt 文案的写法、结构、风格或目标；业务侧 MAY 自由迭代文案

#### Scenario: SCHEMA_SUFFIX 不与 user message 段重复

- **WHEN** engine 调用 judge LLM
- **THEN** `JUDGE_OUTPUT_SCHEMA_SUFFIX` MUST 仅追加到 system prompt 末尾；MUST NOT
  在 user message 段重复追加；user message 末尾仅保留 `按上述系统提示的 JSON
  schema 输出。` 一句作为 dashscope OpenAI-compat JSON mode 的字面 `json` 兜底

#### Scenario: 不跟 polish 端共用同一历史拼装

- **WHEN** engine 调用 polish LLM
- **THEN** polish 的 user message MUST 仍按 polish 自己的规则（N 个 candidate 列
  表）拼装；MUST NOT 共用本 Requirement 的对话历史段；本 Requirement 仅约束 judge
  端拼装

## Data Schema

| 字段 / 表 | 用途 |
|---|---|
| `prompt_version` | id, scope_type (`role` / `judge` / `polish`), scope_id, content, created_at, created_by, is_active |
| `role_config.current_prompt_version_id` | FK 指向当前生效版本 |
| `call_record.prompt_versions` (JSONB) | 通话开始时的 prompt 版本快照 |
| `role_config.model`, `temperature`, `top_p`, `ext_params` (JSONB) | LLM 调用参数 |
