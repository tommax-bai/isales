## Purpose

定义通话目标达成的判定时机、判定信号与达成后的收尾行为。目标判定 SHALL 在通话期间实时完成（不离线判定），由角色 LLM 在 JSON 输出中自带结构化标记驱动；达成后进入 WRAPPING_UP 状态再聊几句主动挂断。

## Requirements

### Requirement: 实时目标达成判定

目标达成判定 SHALL 由角色 LLM 在每一轮 JSON 输出中自行完成，engine MUST 实时读取该输出；通话结束后 worker MUST NOT 再次判定，仅记录最后一轮的标记。

#### Scenario: 角色 LLM 输出契约

- **WHEN** 角色 LLM 被调用生成回复
- **THEN** 输出 MUST 严格遵循 JSON 格式：`{reply, goal_achieved, goal_type, extracted}`，其中 `goal_achieved` 为 bool，`goal_type` 在未达成时为空字符串

#### Scenario: worker 不重复判定

- **WHEN** worker 处理通话结束消息
- **THEN** `summarize_call` 仅生成摘要并把最后一轮的 `goal_achieved` / `goal_type` / `extracted` 写入 `call_summary`，MUST NOT 触发独立的目标判定 LLM 调用

### Requirement: 目标定义在 prompt 中

Campaign 表 MUST NOT 固化目标 schema；目标定义、判定准则、可提取字段名 SHALL 全部写在角色 prompt 中。

#### Scenario: 多目标 / 自定义类型支持

- **WHEN** 业务需要支持多个 goal_type（如 `appointment` / `wechat_added` / `intent_confirmed`）
- **THEN** Campaign 创建者通过修改角色 prompt 实现，无需 DB schema 变更

### Requirement: 三层管线对结构化标记的处理

裁判 LLM SHALL 仅审 `reply` 字段；润色 LLM SHALL 仅改写 `reply` 做拟人化，标记字段（goal_achieved/goal_type/extracted）MUST 从被选中候选直接继承（**不做投票合并**）。

#### Scenario: 裁判审查范围

- **WHEN** 裁判 LLM 接收候选输入
- **THEN** 输入 MUST 仅包含 `reply` 字段；标记字段不参与合规审查

#### Scenario: 润色对标记的处理

- **WHEN** 润色 LLM 选定某个候选作为最终输出
- **THEN** 润色后的最终结果 MUST 复用该候选的 `goal_achieved` / `goal_type` / `extracted`，MUST NOT 对 N 个候选的标记进行投票或合并

### Requirement: 进入 WRAPPING_UP 状态

当润色返回 `goal_achieved=true` 时，engine SHALL 立即进入 WRAPPING_UP 状态，并 MUST 切换 prompt 与简化管线。

#### Scenario: 当前轮回复正常播放

- **WHEN** 润色返回 `goal_achieved=true`
- **THEN** engine 先正常 TTS 播放当前轮 reply，再进入 WRAPPING_UP

#### Scenario: 切换到简化管线

- **WHEN** 进入 WRAPPING_UP 后用户说话触发新一轮 PROCESSING
- **THEN** 后续轮次 MUST 走简化管线（单角色 LLM 直出 + 润色拟人化），**MUST NOT 启用 PK / 裁判**

#### Scenario: prompt 末尾追加收尾指令

- **WHEN** 在 WRAPPING_UP 状态调用角色 LLM
- **THEN** engine MUST 在原 system prompt 末尾追加「目标已达成。请简短确认或告别后结束对话，不要再尝试推进新议题」段落，原 prompt 内容保持不变

### Requirement: 收尾双计数器与主动挂断

WRAPPING_UP 状态 SHALL 同时维护轮数计数器与时长计数器，**任一耗尽时**主动挂断。

#### Scenario: 轮数耗尽先到达

- **WHEN** WRAPPING_UP 期间已完成的对话轮数达到 `campaign.wrap_up_max_rounds`（默认 2）
- **THEN** engine 播放 `campaign.wrap_up_closing_phrases` 中随机一条后主动挂断，进入 END (reason=`wrap_up_completed`)

#### Scenario: 时长耗尽先到达

- **WHEN** WRAPPING_UP 累计时长达到 `campaign.wrap_up_max_seconds`（默认 15s）
- **THEN** 同上：播放挂断话术后挂断

### Requirement: 收尾期间的特殊情况处理

WRAPPING_UP 状态下用户的非常规行为 SHALL 按以下规则处理；engine MUST NOT 退回主管线（避免反复无效循环）。

#### Scenario: 用户提出新问题

- **WHEN** WRAPPING_UP 期间用户说出与目标无关的新问题
- **THEN** engine SHALL 继续走简化管线回应，MUST NOT 退回主管线

#### Scenario: 用户主动挂断

- **WHEN** WRAPPING_UP 期间用户挂机
- **THEN** engine 直接进入 END

#### Scenario: 用户明确反悔

- **WHEN** WRAPPING_UP 期间用户表示反悔（如「我再想想」）
- **THEN** engine SHALL 仍按收尾流程结束，MUST NOT 退回主管线（避免反复）

#### Scenario: 转人工触发

- **WHEN** WRAPPING_UP 期间任何转人工触发条件命中
- **THEN** 收尾流程 SHALL 让位，engine 进入 TRANSFERRING

### Requirement: 通话结束后回调匹配

worker 的 `process_callbacks` SHALL 通过 `callback_config.trigger`（JsonLogic 表达式）匹配 `goal_achieved` / `goal_type` / `extracted.*` 字段触发外部 webhook（详见 webhook-callback 规范）。

#### Scenario: 简单 trigger 示例

- **WHEN** 通话最后一轮 `goal_achieved=true && goal_type="appointment"`
- **THEN** 满足 `{"and": [{"==": [{"var": "goal_achieved"}, true]}, {"==": [{"var": "goal_type"}, "appointment"]}]}` 的 callback_config 触发

## Data Schema

| 表 / 字段 | 用途 |
|---|---|
| `call_record.wrap_up_started_at` | 进入 WRAPPING_UP 的时刻，用于追踪和时长计算 |
| `call_summary.goal_achieved` | 通话最后一轮的标记 |
| `call_summary.goal_type` | 通话最后一轮的目标类型 |
| `call_summary.extracted_fields` (JSONB) | 通话最后一轮的提取字段 |
| `campaign.wrap_up_max_rounds` | 收尾轮数上限 |
| `campaign.wrap_up_max_seconds` | 收尾时长上限 |
| `campaign.wrap_up_closing_phrases` (JSONB) | 收尾挂断话术池 |
| `campaign.extraction_fields` (JSONB) | 字段抽取的配置参考（具体抽取由角色 LLM 完成） |

## Design Trade-off

单角色误报目标达成的风险由"角色 prompt 设计 + 收尾期间用户的反应"两层兜底，不在润色层做投票合并。代价：单次单轮误报概率高于投票方案，需在 prompt 中强约束判定标准。收益：实现简单、延迟低；即使 AI 误以为达成，用户在收尾对话中也会自然纠正。
