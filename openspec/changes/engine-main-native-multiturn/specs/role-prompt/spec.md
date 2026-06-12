## MODIFIED Requirements

### Requirement: Prompt 三段式组装

每次调用 main LLM 时 engine SHALL 按以下结构组装：1 条 system message + 由 `dialog_history` 映射出的**原生多轮 chat message**（user / assistant 交替）。会话级静态上下文（上次通话纪要、线索信息）置于 system message，不再混入对话轮次。

#### Scenario: System message 内容

- **WHEN** 组装 main LLM 的 system message
- **THEN** 内容 MUST = 角色身份 + 目标定义 + **纯文本输出约束**（详见 § "main system prompt 内容规范"）；MAY 在末尾追加收尾指令（仅 WRAPPING_UP 期间）

#### Scenario: 会话级静态上下文置于 system message

- **WHEN** 组装 main LLM 的 system message
- **THEN** 在 system prompt 主体与各追加段（收尾 / 跟进）之外，engine MUST 把以下会话级静态上下文附入 system message：
  1. 【上次通话纪要】（仅跟进时存在）
  2. 【线索信息】name, phone, custom_data 等
- **AND** 这两段 MUST NOT 出现在任何对话轮次的 message 中（它们是上下文而非对话发言）

#### Scenario: 对话历史映射为多轮 message

- **WHEN** 组装 main LLM 的对话部分
- **THEN** engine MUST 按时间顺序遍历 `dialog_history`，每个 turn emit 一条独立 chat message：
  1. `role=assistant`：来自 greeting / ai_reply 事件
  2. `role=user`：来自 user_speech 事件
- **AND** MUST NOT 把对话拼成单段文本，MUST NOT 追加末尾 `AI:` 文本钩子（最新用户发言天然是数组中最后一条 user message，模型据此生成下一条 assistant 回复）

#### Scenario: 使用标准 chat multi-turn

- **WHEN** 调用 main LLM Provider 的 chat completion 接口
- **THEN** engine MUST 传入多条 message（system + 多轮 user/assistant）；MUST NOT 把整通对话压成单条 user message 文本

### Requirement: 对话过长不做截断

v1 SHALL 不做对话历史的截断或摘要，依赖 LLM 长上下文能力。每个 Provider 接入时 MUST 记录 token 用量并接入监控告警。

#### Scenario: 长通话依赖长上下文

- **WHEN** 通话进行 30 轮以上
- **THEN** engine MUST 仍把全部历史作为多轮 message 传入；MUST NOT 自动截断或调用摘要 LLM

#### Scenario: token 用量监控

- **WHEN** Provider 返回 token 用量信息
- **THEN** engine SHALL 记录到 pipeline_trace；超阈值 MUST 触发告警（避免成本失控）

### Requirement: 跟进通话的 prompt 增强

跟进通话调用角色 LLM 时 engine SHALL 在 system prompt 末尾追加跟进上下文段落（紧跟收尾指令之前）。上次通话摘要 SHALL 由 scheduler 在 dial 队列消息中携带，engine MUST NOT 直接查 DB。

#### Scenario: 跟进段落格式

- **WHEN** 通话是跟进通话（is_follow_up=true, follow_up_count=N）
- **THEN** system prompt 末尾追加：
  ```
  【跟进上下文】
  这是对该用户的第 N 次跟进。上次通话结束于 {timestamp}。
  请根据上述【上次通话纪要】调整开场和后续话术，避免重复内容。
  ```
- **AND** 因【上次通话纪要】context 段在 system message 中位于跟进指令之上（见 § "Prompt 三段式组装"），措辞 MUST 用「上述」而非「下面的」

#### Scenario: 历史摘要由 scheduler 注入到 system message context 段

- **WHEN** scheduler 派发跟进通话
- **THEN** dial 消息 MUST 携带 `last_call_summary` 字段；engine SHALL 把该摘要放入 system message 的【上次通话纪要】context 段（见 § "Prompt 三段式组装" 的「会话级静态上下文置于 system message」scenario），MUST NOT 自行查 call_summary 表
