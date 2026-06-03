## MODIFIED Requirements

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

## ADDED Requirements

### Requirement: referee prompt 内容规范

referee LLM system prompt SHALL 严格指定输出 JSON schema + 决策枚举语义。MUST 显式说明 4 个 decision 枚举各自的判定标准（避免小模型误判）。

```
你是销售外呼对话的决策助手。基于"用户最后一句话"+ 最近 3 轮对话历史，判断本轮对话状态。

【输入】
用户最后一句话：{{user_last_utterance}}
最近 3 轮对话：
{{recent_dialog_history}}

【输出 JSON】
{
  "decision": "continue" | "goal_achieved" | "customer_decline" | "transfer",
  "goal_type": "appointment" | "sale" | "callback" | null,
  "confidence": 0.0~1.0
}

【枚举语义】
- continue: 客户在正常对话中（包括犹豫 / 询问细节），不需要状态切换
- goal_achieved: 客户明确同意了外呼目标（成交 / 约见 / 同意回访）。goal_type 必填
- customer_decline: 客户明确拒绝或表达强烈反感
- transfer: 客户主动要求转人工

【confidence 评分】
- 你的判断越确定，confidence 越接近 1.0
- 模棱两可时给低分；< 0.7 系统会忽略你的决策走 continue

只输出 JSON，不要任何解释。
```

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

## REMOVED Requirements

### Requirement: JSON Mode 强制策略（两步保护）

**Reason**: main LLM 改为纯文本输出，不再走 JSON Mode。referee 与 extractor 仍用 JSON Mode 但通过 `chat(json_mode=True)` 接口直接调用，不需要"两步保护"机制（输入短 + 输出严格 schema，错率本身低；fail-open 由 ai-pipeline § "校验失败 fail-open" Scenario 覆盖）。

**Migration**: 无需迁移。Provider ABC 仍保留 `supports_json_mode` 字段供 referee / extractor 使用。

### Requirement: Judge 拿到对话上下文

**Reason**: judge layer 完全删除。Judge 拿对话历史的设计思路（5/29 archive `engine-judge-dialog-context`）继承到 referee LLM —— referee 也用最近 ≤ 3 轮 dialog_history 作为输入。

**Migration**: 
- `archive/2026-05-29-engine-judge-dialog-context/` 标 `SUPERSEDED-by-pipeline-stream-and-referee`
- 原 `_render_dialog_history_for_judge()` 函数删除；新增 `_render_dialog_history_for_referee()` 函数（实装继承原渲染规则：全角冒号 / `用户：` / `AI：` 前缀 / 占位 `（首轮对话，无历史）`）
- 原 `JUDGE_OUTPUT_SCHEMA_SUFFIX` 常量删除；新增 `REFEREE_OUTPUT_SCHEMA_SUFFIX` 常量（schema 不同，见 § "referee prompt 内容规范"）
