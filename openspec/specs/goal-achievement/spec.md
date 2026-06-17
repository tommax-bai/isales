## Purpose

定义通话目标达成的判定时机、判定信号与达成后的收尾行为。目标判定 SHALL 在通话期间实时完成（不离线判定），由角色 LLM 在 JSON 输出中自带结构化标记驱动；达成后进入 WRAPPING_UP 状态再聊几句主动挂断。
## Requirements
### Requirement: 实时目标达成判定

目标达成判定 SHALL 由「某个 referee 输出的 category + 一条 action 命中 `closing` route（或 legacy `transition to=goal_achieved`，经 shim 映射为 `closing` route）」共同决定（替代原单 referee `decision="goal_achieved"` 字段）。`goal_type` SHALL 取自命中规则 action 的 `goal_type` 字段，而非 referee 输出；该提取 MUST 对 `route` 与 legacy `transition` 两种 action 形态对称——engine MUST NOT 仅对 `transition` 提取 `goal_type` 而在 `route` 形态丢弃它。判定发生在**开口前门控**：门控选中 `closing` route → 播放收尾风格回复（MainSpec + 收尾追加）→ 由其 `then_state=WRAPPING_UP` 经 StatusProjector 投影进 WRAPPING_UP；engine MUST NOT 在 route 内直接 `sm.transition_to`。通话结束后 worker MUST NOT 再次判定 goal_achieved（仅 post-call extractor 抽取 `extracted` 字段入库，与 goal_achieved 判定无关）；worker 读取 goal 标记 SHALL 以 transcript 中的规范事件类型 `ai_reply`（及达成里程碑 `goal_achieved` 事件）为唯一来源。

#### Scenario: 规则命中选 closing route 投影 WRAPPING_UP

- **WHEN** 某 referee 返回判定「已约到」的 category 且对应 routing rule action 为 `{type: route, to: closing, then_state: WRAPPING_UP}`（或 legacy `{type: transition, to: goal_achieved, goal_type: appointment}` 经 shim 映射为 closing route）
- **THEN** engine SHALL 由门控选中 `closing` route 放行收尾风格回复，其 `then_state=WRAPPING_UP` 经 StatusProjector 投影进 WRAPPING_UP；MUST NOT 在 route/decider 内直接 `sm.transition_to`
- **AND** `goal_type` MUST 取自规则 action 而非 referee 输出

#### Scenario: route 与 transition 动作的 goal_type 提取对称

- **WHEN** 命中规则的 action 为 `{type: route, to: closing, goal_type: X}`（modern 形态）
- **THEN** engine 的规则决策层（decider）MUST 从该 action 提取 `goal_type=X` 并沿门控选路一路透传，使最终 `goal_achieved` 事件携带 `goal_type=X`
- **AND** 该提取行为 MUST 与 legacy `{type: transition, to: goal_achieved, goal_type: X}` 形态产生一致结果，MUST NOT 出现「`transition` 携带 `goal_type` 而 `route` 丢弃为空」的不对称

#### Scenario: 多 referee 下目标判定优先级

- **WHEN** 多个 referee 同轮返回结果，且 routing_rules 中 goal_achieved/closing 规则排在某 restructure 规则之前
- **THEN** engine SHALL 按 first-match-wins 选 closing route（先命中者生效），与规则数组顺序一致

#### Scenario: worker 不重复判定

- **WHEN** worker 处理通话结束消息
- **THEN** `summarize_call` 仅生成摘要并把通话过程中最后一次命中 goal_achieved/closing 规则的 `goal_type` 写入 `call_summary`，MUST NOT 触发独立的目标判定 LLM 调用
- **AND** worker 的 `post_call_extractor` consumer 仅抽 `extracted` 字段，MUST NOT 重判 goal_achieved

#### Scenario: worker 从 ai_reply 事件读取 goal 标记

- **WHEN** worker 的 `summarize_call`（及其 provider）从 transcript 读取 `goal_achieved` / `goal_type` / `extracted` 结构化标记
- **THEN** 消费方 MUST 从规范事件类型 `ai_reply`（携带这些字段，见 `transcript` spec § 事件类型枚举）读取——取倒序最近一条携带该标记的 `ai_reply` 事件；达成轮另写的独立 `goal_achieved` 里程碑事件亦为合法来源
- **AND** 消费方 MUST NOT 依据已废弃的 `bot_speech` 事件名读取（该事件名在 `2026-06-10-fix-transcript-schema-drift` 后引擎不再产出，transcript 事件枚举中亦无此类型）；读不到标记时 MUST fail-safe 视为未达成（`goal_achieved=false`）而非报错
- **AND** 摘要正文拼接 SHALL 同样以 `ai_reply` 作为 AI 侧话语来源，MUST NOT 因事件名不匹配而丢失 AI 回复文本

#### Scenario: 目标定义仍在 prompt + 规则中，不固化 schema

- **WHEN** campaign 要新增一种目标类型
- **THEN** 创建者 SHALL 通过「在某 referee prompt 加判定语义 + 在 routing_rules 加一条 closing route 规则（带新 goal_type）」实现，MUST NOT 需要 DB schema 变更

### Requirement: 目标定义在 prompt 中

Campaign 表 MUST NOT 固化目标 schema；目标定义、判定准则、可提取字段名 SHALL 全部写在 **referee prompt** 与 **extractor prompt** 中（分别承担"达成判定"与"信息抽取"两个职责）。

#### Scenario: 多目标 / 自定义类型支持

- **WHEN** 业务需要支持多个 goal_type（如 `appointment` / `wechat_added` / `intent_confirmed`）
- **THEN** Campaign 创建者通过修改 referee prompt 的"枚举语义"段实现，无需 DB schema 变更
- **AND** extractor prompt 同步支持自定义字段集，由 Campaign 自定义

### Requirement: 进入 WRAPPING_UP 状态

当门控选中 `closing` route（goal_achieved 软结局）时，engine SHALL 放行该 route 的收尾风格回复，并由其 `then_state=WRAPPING_UP` 经 StatusProjector 投影进 WRAPPING_UP 状态，MUST 切换 prompt 与简化管线。因门控在**开口前**裁决，被选 `closing` route 的回复**就是**本轮播出的回复——不存在"先播 main 回复再转移"的二段，故无需 hold referee 到 SPEAKING 结束。

#### Scenario: closing route 的回复即本轮回复

- **WHEN** 门控选中 `closing` route
- **THEN** engine SHALL 放行 closing route 的收尾风格回复（MainSpec + 收尾追加）作为本轮 TTS 播出；`then_state=WRAPPING_UP` 投影状态；MUST NOT 另起一段 main 回复，MUST NOT 中途打断已放行的 closing 回复

#### Scenario: 门控裁决先于音频

- **WHEN** referee 门控比对话首句预合成更早完成（典型情况，referee 输入短）
- **THEN** engine 在释放音频前即完成选路（closing vs main vs 其它）；MUST NOT 出现"先放 main 音频又要回退转 WRAPPING_UP"的旧时序竞态

#### Scenario: 切换到简化管线

- **WHEN** 进入 WRAPPING_UP 后用户说话触发新一轮 PROCESSING
- **THEN** 后续轮次 MUST 走简化管线（仅 main LLM streaming，跳 referee）；详见 `ai-pipeline` spec § "简化管线（WRAPPING_UP）"

#### Scenario: prompt 末尾追加收尾指令

- **WHEN** 在 WRAPPING_UP 状态调用 main LLM
- **THEN** engine MUST 在原 main system prompt 末尾追加「目标已达成。请简短确认或告别后结束对话，不要再尝试推进新议题」段落，原 prompt 内容保持不变（详见 `role-prompt` spec § "收尾期间在 system prompt 末尾追加指令"）

### Requirement: 收尾双计数器与主动挂断

WRAPPING_UP 状态 SHALL 同时维护轮数计数器与时长计数器，作为收尾的**兜底（safety-net）**终止条件，**任一耗尽时**主动挂断。计数器耗尽属于"硬上限"，不是收尾期唯一的主动终止路径——收尾期客户静默亦会触发主动挂断（见「收尾期间的特殊情况处理」），二者覆盖互斥的输入（前者为对话持续不收敛，后者为客户不再开口）。

计数器耗尽的挂断 reason SHALL 限定为 `wrap_up_completed`（transcript 事件 `wrap_up_completed.reason` 取值为封闭枚举 `max_rounds` / `max_seconds`）。收尾期其它主动挂断路径（如客户静默）MUST NOT 复用或扩宽该 reason 词汇，改用各自的 `hangup` 事件 reason，以避免 transcript schema 漂移。

#### Scenario: 轮数耗尽先到达

- **WHEN** WRAPPING_UP 期间已完成的对话轮数达到 `campaign.wrap_up_max_rounds`（默认 2）
- **THEN** engine 播放 `campaign.wrap_up_closing_phrases` 中随机一条后主动挂断，进入 END (reason=`wrap_up_completed`)

#### Scenario: 时长耗尽先到达

- **WHEN** WRAPPING_UP 累计时长达到 `campaign.wrap_up_max_seconds`（默认 15s）
- **THEN** 同上：播放挂断话术后挂断

### Requirement: 收尾期间的特殊情况处理

WRAPPING_UP 状态下用户的非常规行为 SHALL 按以下规则处理；engine MUST NOT 退回主管线（避免反复无效循环）。

WRAPPING_UP 期间 engine 的静音判定 SHALL 与通话中段不同：通话中段静音走「重新激活（如『你好，还在么？』）→ 多次后挂断」阶梯；而收尾期客户静默时 engine MUST NOT 播放任何重新激活话术，而是静默达 `campaign.wrap_up_silence_hangup_ms` 后直接主动挂断。该行为对所有 campaign 全局生效（收尾期仍做重新激活即此前的缺陷行为），不设 per-campaign 开关。收尾期静音判定 SHALL 复用既有静音机制并按收尾阶段分支，MUST NOT 新建独立的第二条静音判定路径。

#### Scenario: 用户提出新问题

- **WHEN** WRAPPING_UP 期间用户说出与目标无关的新问题
- **THEN** engine SHALL 继续走简化管线回应，MUST NOT 退回主管线

#### Scenario: 客户静默后主动挂断

- **WHEN** WRAPPING_UP 期间客户连续静默达到 `campaign.wrap_up_silence_hangup_ms`（默认 6000ms，SHALL 配置为长于通话中段 `campaign.silence_threshold_ms`，给客户在告别语后留思考时间）
- **THEN** engine SHALL 直接进入 END，发 `hangup` 事件（`reason="wrap_up_silence"`, `initiated_by="ai"`）
- **AND** engine MUST NOT 播放任何 `silence_activation` 重新激活话术（如「你好，还在么？」）
- **AND** engine MUST NOT 将该终止写入 `wrap_up_completed.reason`（其为封闭枚举），亦 SHALL 复用 `HangupCause.SILENCE_MAX_REACHED` 而非新增枚举

#### Scenario: 客户在收尾静默窗口内再次开口

- **WHEN** WRAPPING_UP 期间客户在静默达到 `campaign.wrap_up_silence_hangup_ms` 之前再次说话
- **THEN** 收尾静默窗口 SHALL 重置，engine 按简化管线正常回应，MUST NOT 因先前静默而挂断（避免打断慢思考的客户）

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

worker 的 `process_callbacks` SHALL 通过 `callback_config.trigger`（JsonLogic 表达式）匹配 `goal_achieved` / `goal_type` / `extracted.*` 字段触发外部 webhook（详见 webhook-callback 规范）。**`extracted` 字段由 post-call extractor 异步写入；callback 触发 SHALL 等 `call_record.extract_status='done'` 之后才发**（避免 callback 拿到空 extracted）。

#### Scenario: 简单 trigger 示例

- **WHEN** 通话最后一轮 `goal_achieved=true && goal_type="appointment"` 且 extract_status='done'
- **THEN** 满足 `{"and": [{"==": [{"var": "goal_achieved"}, true]}, {"==": [{"var": "goal_type"}, "appointment"]}]}` 的 callback_config 触发

#### Scenario: extract_status 未就绪时延迟触发

- **WHEN** 通话 END 时 `extract_status='pending'`（worker 还没处理完 extract 任务）
- **THEN** worker 的 callback 处理 SHALL 延迟到 `extract_status` 变更（done 或 failed）之后再触发；如果 extract_status='failed'，callback 触发时 extracted 字段为 null

## Data Schema

| 表 / 字段 | 用途 |
|---|---|
| `call_record.wrap_up_started_at` | 进入 WRAPPING_UP 的时刻，用于追踪和时长计算 |
| `call_summary.goal_achieved` | 通话最后一轮的标记 |
| `call_summary.goal_type` | 通话最后一轮的目标类型 |
| `call_summary.extracted_fields` (JSONB) | 通话最后一轮的提取字段 |
| `campaign.wrap_up_max_rounds` | 收尾轮数上限（兜底） |
| `campaign.wrap_up_max_seconds` | 收尾时长上限（兜底） |
| `campaign.wrap_up_closing_phrases` (JSONB) | 收尾挂断话术池 |
| `campaign.wrap_up_silence_hangup_ms` | 收尾期客户静默主动挂断阈值（默认 6000ms，长于 `silence_threshold_ms`；收尾期跳过重新激活直接挂断） |
| `campaign.extraction_fields` (JSONB) | 字段抽取的配置参考（具体抽取由角色 LLM 完成） |

## Design Trade-off

单角色误报目标达成的风险由"角色 prompt 设计 + 收尾期间用户的反应"两层兜底，不在润色层做投票合并。代价：单次单轮误报概率高于投票方案，需在 prompt 中强约束判定标准。收益：实现简单、延迟低；即使 AI 误以为达成，用户在收尾对话中也会自然纠正。
