## MODIFIED Requirements

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
