## MODIFIED Requirements

### Requirement: 实时目标达成判定

目标达成判定 SHALL 由 **referee LLM** 在每一轮 PROCESSING 旁路决策中完成（与 main LLM 并行 spawn，详见 `ai-pipeline` spec § "referee LLM 二级决策"），engine MUST 实时读取该输出驱动状态机；通话结束后 worker MUST NOT 再次判定 goal_achieved（仅 post-call extractor 抽取 `extracted` 字段入库，与 goal_achieved 判定无关）。

#### Scenario: referee LLM 输出契约

- **WHEN** referee LLM 被调用做本轮决策
- **THEN** 输出 MUST 严格遵循 JSON `{decision, goal_type, confidence}`（详见 `role-prompt` spec § "referee prompt 内容规范"）
- **AND** `decision="goal_achieved"` 时 `goal_type` MUST 非空（`appointment` / `sale` / `callback` 等 Campaign 自定义枚举）

#### Scenario: worker 不重复判定

- **WHEN** worker 处理通话结束消息
- **THEN** `summarize_call` 仅生成摘要并把通话过程中最后一次 referee 返回 `goal_achieved=true` 的 `goal_type` 写入 `call_summary`，MUST NOT 触发独立的目标判定 LLM 调用
- **AND** worker 的 `post_call_extractor` consumer 仅抽 `extracted` 字段，MUST NOT 重判 goal_achieved

### Requirement: 目标定义在 prompt 中

Campaign 表 MUST NOT 固化目标 schema；目标定义、判定准则、可提取字段名 SHALL 全部写在 **referee prompt** 与 **extractor prompt** 中（分别承担"达成判定"与"信息抽取"两个职责）。

#### Scenario: 多目标 / 自定义类型支持

- **WHEN** 业务需要支持多个 goal_type（如 `appointment` / `wechat_added` / `intent_confirmed`）
- **THEN** Campaign 创建者通过修改 referee prompt 的"枚举语义"段实现，无需 DB schema 变更
- **AND** extractor prompt 同步支持自定义字段集，由 Campaign 自定义

### Requirement: 进入 WRAPPING_UP 状态

当 referee 返回 `decision="goal_achieved" && confidence >= 0.7` 时，engine SHALL 立即（main TTS 播完后）进入 WRAPPING_UP 状态，并 MUST 切换 prompt 与简化管线。

#### Scenario: 当前轮 main 回复正常播放

- **WHEN** referee 返回 `decision="goal_achieved" && confidence >= 0.7`，且 main LLM streaming 仍在进行
- **THEN** engine 先让 main TTS 完整播完当前轮 reply，再进入 WRAPPING_UP；MUST NOT 中途打断 main TTS

#### Scenario: referee 早于 main 完成

- **WHEN** referee LLM 调用比 main LLM 更早完成（典型情况，referee 输入短）
- **THEN** engine MUST 把 referee 结果 hold 住到 SPEAKING 状态结束（main TTS 播完）才转移；MUST NOT 提前转移导致 main TTS 中断

#### Scenario: 切换到简化管线

- **WHEN** 进入 WRAPPING_UP 后用户说话触发新一轮 PROCESSING
- **THEN** 后续轮次 MUST 走简化管线（仅 main LLM streaming，跳 referee）；详见 `ai-pipeline` spec § "简化管线（WRAPPING_UP）"

#### Scenario: prompt 末尾追加收尾指令

- **WHEN** 在 WRAPPING_UP 状态调用 main LLM
- **THEN** engine MUST 在原 main system prompt 末尾追加「目标已达成。请简短确认或告别后结束对话，不要再尝试推进新议题」段落，原 prompt 内容保持不变（详见 `role-prompt` spec § "收尾期间在 system prompt 末尾追加指令"）

### Requirement: 通话结束后回调匹配

worker 的 `process_callbacks` SHALL 通过 `callback_config.trigger`（JsonLogic 表达式）匹配 `goal_achieved` / `goal_type` / `extracted.*` 字段触发外部 webhook（详见 webhook-callback 规范）。**`extracted` 字段由 post-call extractor 异步写入；callback 触发 SHALL 等 `call_record.extract_status='done'` 之后才发**（避免 callback 拿到空 extracted）。

#### Scenario: 简单 trigger 示例

- **WHEN** 通话最后一轮 `goal_achieved=true && goal_type="appointment"` 且 extract_status='done'
- **THEN** 满足 `{"and": [{"==": [{"var": "goal_achieved"}, true]}, {"==": [{"var": "goal_type"}, "appointment"]}]}` 的 callback_config 触发

#### Scenario: extract_status 未就绪时延迟触发

- **WHEN** 通话 END 时 `extract_status='pending'`（worker 还没处理完 extract 任务）
- **THEN** worker 的 callback 处理 SHALL 延迟到 `extract_status` 变更（done 或 failed）之后再触发；如果 extract_status='failed'，callback 触发时 extracted 字段为 null

## REMOVED Requirements

### Requirement: 三层管线对结构化标记的处理

**Reason**: 三层管线删除。原"裁判审 reply / 润色继承标记"规则在双 LLM 架构下不复存在——main LLM 不再输出 JSON，referee 独立决策 `goal_achieved` / `goal_type`，extractor 独立抽取 `extracted`。三个职责被三个 LLM 解耦。

**Migration**: 
- 原 `goal_achieved` / `goal_type` 触发来源从 polish LLM JSON 字段改为 referee LLM `decision` 枚举，状态机转移逻辑不变
- 原 `extracted` 触发来源从 polish LLM JSON 字段改为 post-call extractor 异步写入 `call_record.extracted`
- `call_summary.extracted_fields` 字段保留但弃用（迁至 `call_record.extracted`）；alembic migration 把已有 `call_summary.extracted_fields` 数据复制到 `call_record.extracted`
