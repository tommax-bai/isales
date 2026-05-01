## ADDED Requirements

### Requirement: 跨服务消息体集中定义在 isales-common

所有跨服务的 Redis 消息体（队列消息与 Pub/Sub 事件）SHALL 在 `isales_common/schemas/messages/` 模块下定义为 Pydantic 模型；任何服务的 producer / consumer MUST 引用同一模型类，MUST NOT 自行定义平行结构或裸用 dict。

#### Scenario: producer 写入 Redis

- **WHEN** 任何服务向 Redis 队列 / Pub/Sub 写入消息
- **THEN** 消息体 SHALL 由 isales-common 的对应 Pydantic 类构造，调用 `.model_dump_json()` 序列化；MUST NOT 直接构造 dict 后 `json.dumps()`

#### Scenario: consumer 读取 Redis

- **WHEN** 任何服务从 Redis 读取消息
- **THEN** SHALL 用 isales-common 的对应类 `model_validate_json()` 反序列化；MUST NOT 用 `json.loads()` 后裸取字段

#### Scenario: 引入新通信场景

- **WHEN** service-communication spec 中新增一条通道（如新增 worker → api 的事件推送）
- **THEN** isales-common MUST 同步新增对应消息类；MUST 经 OpenSpec change proposal

### Requirement: 消息基类与版本字段

所有消息类 SHALL 继承统一基类 `BaseMessage`，包含字段：`schema_version: int`（默认 1，破坏性升级时 +1）、`message_id: UUID`（producer 生成，便于追踪去重）、`created_at: datetime`（producer 时间戳）。

#### Scenario: 基础字段必填

- **WHEN** 实例化任何具体消息类
- **THEN** `schema_version` / `message_id` / `created_at` MUST 自动填充（基类提供默认值或 factory）

#### Scenario: consumer 校验 schema_version

- **WHEN** consumer 反序列化消息
- **THEN** SHALL 校验 `schema_version` 是否在自己支持的范围内；不支持的版本 MUST 显式日志告警并按 dead letter 处理，MUST NOT 静默丢弃

### Requirement: 通道矩阵覆盖完整

isales-common 的消息 schema 集合 SHALL 覆盖 `service-communication` spec 通道矩阵中标注为"含消息体"的所有跨服务通道；遗漏 MUST 视为 spec drift 缺陷。

#### Scenario: v1 必有的消息类

- **WHEN** 清点 isales-common 的消息 schema 集合
- **THEN** MUST 至少包含：
  - `DialRequest`（scheduler → engine queue：lead 信息 + 历史摘要 + prompt_versions 快照 + caller_id）
  - `CallEnded`（engine → worker queue：call_record_id + 终止原因）
  - `EngineControl`（api → engine pub/sub：手动挂断 / 转人工指令；用 discriminated union 覆盖子类型）
  - `EngineEvent`（engine → api pub/sub：状态变更 / ASR 文本 / transcript 增量；discriminated union）
  - `CampaignControl`（api → scheduler queue：启动 / 暂停 campaign）

### Requirement: 演进规则

消息 schema 的演进 SHALL 区分"非破坏性"与"破坏性"两类：非破坏性变更 MAY 直接合入并保持 `schema_version` 不变；破坏性变更 MUST 升 `schema_version` 并经 OpenSpec change proposal。

#### Scenario: 非破坏性变更

- **WHEN** 新增的字段是可选（带默认值）且老 consumer 忽略不影响业务
- **THEN** MAY 直接修改类定义并合入；不需升 `schema_version`

#### Scenario: 破坏性变更

- **WHEN** 删除字段、改字段类型、改字段语义、新增必填字段
- **THEN** MUST 在 OpenSpec change 中明确列出影响范围；MUST 升 `schema_version`；MUST 在迁移期内同时支持新旧两版反序列化（discriminated union 或并存类）

### Requirement: 消息类禁止承载业务逻辑

消息类 SHALL 仅描述数据形状；MUST NOT 包含调用 Redis 的方法、业务校验之外的副作用、或对 isales-common 之外模块的依赖。

#### Scenario: 仅纯数据类

- **WHEN** 在消息类中实现方法
- **THEN** SHALL 仅限于 Pydantic validator / serializer / 计算字段；MUST NOT 直接发起网络调用或 DB 操作

### Requirement: 序列化与可观测性

消息序列化 SHALL 使用 Pydantic 的 `.model_dump_json()`（默认 JSON）；消息基类 SHALL 提供便于日志输出的 `__str__`（含 `message_id` 与类名），便于跨服务 tracing。

#### Scenario: 日志含 message_id

- **WHEN** producer 写入 / consumer 处理消息
- **THEN** 关键日志行 SHALL 含 `message_id`，使跨服务排查能用 `grep` 串起完整链路
