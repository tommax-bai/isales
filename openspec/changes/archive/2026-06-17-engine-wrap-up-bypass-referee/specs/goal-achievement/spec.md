## MODIFIED Requirements

### Requirement: 收尾期间的特殊情况处理

WRAPPING_UP 状态下用户的非常规行为 SHALL 按以下规则处理；engine MUST NOT 退回主管线（避免反复无效循环）。

WRAPPING_UP 期间 engine 的静音判定 SHALL 与通话中段不同：通话中段静音走「重新激活（如『你好，还在么？』）→ 多次后挂断」阶梯；而收尾期客户静默时 engine MUST NOT 播放任何重新激活话术，而是静默达 `campaign.wrap_up_silence_hangup_ms` 后直接主动挂断。该行为对所有 campaign 全局生效（收尾期仍做重新激活即此前的缺陷行为），不设 per-campaign 开关。收尾期静音判定 SHALL 复用既有静音机制并按收尾阶段分支，MUST NOT 新建独立的第二条静音判定路径。

当 `campaign.wrap_up_referee_enabled=true` 时，收尾期客户**开口回复**亦受一个旁路收尾裁判判定（见 ai-pipeline § 简化管线）：裁判把客户这句回复二分类为「有实质新问题」/「无实质问题（附和、客套、同意结束、无内容）」；判「无实质问题」时 engine SHALL 在收尾回复播出后**直接主动挂断、不再多播一句**。`wrap_up_referee_enabled=false`（默认）时收尾期不做此判定，客户的任何开口回复一律继续走简化管线（由计数器兜底）。这三类终止——计数器耗尽 / 客户静默 / 裁判判无问题——覆盖互斥输入，互为正交、非堆叠兜底。

#### Scenario: 用户提出新问题

- **WHEN** WRAPPING_UP 期间用户说出与目标无关的新问题（裁判开启时判为「有实质新问题」）
- **THEN** engine SHALL 继续走简化管线回应，MUST NOT 退回主管线，MUST NOT 因裁判而挂断

#### Scenario: 客户回复无实质新问题后主动挂断（裁判开启）

- **WHEN** WRAPPING_UP 期间 `campaign.wrap_up_referee_enabled=true`，客户开口回复但旁路收尾裁判判为「无实质新问题」（仅附和 / 客套 / 同意结束 / 无内容）
- **THEN** engine SHALL 在该轮收尾回复播出后直接进入 END，发 `hangup` 事件（`reason="wrap_up_referee_hangup"`, `initiated_by="ai"`），复用 `tool:hangup → END` 路径，MUST NOT 再多播一句话
- **AND** engine SHALL 复用 `HangupCause.REFEREE_HANGUP`，MUST NOT 写入封闭的 `wrap_up_completed.reason`、MUST NOT 新增枚举
- **AND** 裁判超时 / 报错 / 空输出 时 MUST fail-open 视为非挂断（继续走计数器兜底）；客户打断收尾回复时 MUST 取消裁判任务且不挂断

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
