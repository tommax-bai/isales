## MODIFIED Requirements

### Requirement: 通道矩阵覆盖完整

isales-common 的消息 schema 集合 SHALL 覆盖 `service-communication` spec 通道矩阵中标注为"含消息体"的所有跨服务通道；遗漏 MUST 视为 spec drift 缺陷。

#### Scenario: v1 必有的消息类

- **WHEN** 清点 isales-common 的消息 schema 集合
- **THEN** MUST 至少包含：
  - `DialRequest`（scheduler → engine queue：lead 信息 + 历史摘要 + prompt_versions 快照 + caller_id）
  - `CallEnded`（engine → worker queue：call_record_id + 终止原因）
  - `DeviceReleased`（engine → scheduler queue：`device_id` + `call_record_id` + `ended_at`；通话结束后请求复位该 device 状态）
  - `EngineControl`（api → engine pub/sub：手动挂断 / 转人工指令；用 discriminated union 覆盖子类型）
  - `EngineEvent`（engine → api pub/sub：状态变更 / ASR 文本 / transcript 增量；discriminated union）
  - `CampaignControl`（api → scheduler queue：启动 / 暂停 campaign）

#### Scenario: DeviceReleased 是新增非破坏类

- **WHEN** 引入 `DeviceReleased` 消息类
- **THEN** 它 SHALL 是**新增**的独立消息类（不修改 `CallEnded` 的字段集合）；按「演进规则」属非破坏性变更，MAY 不升 `schema_version`
- **AND** `DeviceReleased` MUST NOT 承载业务逻辑，仅承载复位 device 所需的最小字段（device_id 必填）
