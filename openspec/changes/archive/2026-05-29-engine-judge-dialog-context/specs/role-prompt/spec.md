## ADDED Requirements

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
