## ADDED Requirements

### Requirement: 引擎写时校验 transcript 事件契约

引擎在写入任一 transcript 事件时（`CallSession.append_event`）MUST 用
`isales_common` 的 `TranscriptEvent` 判别联合契约校验该事件的**完整字段**（字段名、
literal 取值、必填项、类型），而不仅校验 `type` 判别符是否在事件类型枚举内。

校验失败时引擎 MUST 记录一条结构化错误日志（含事件 `type` 与校验错误明细）。

生产环境（默认）下，写时校验失败 MUST NOT 中断进行中的通话——transcript 是观测
数据，写入契约违例是工程缺陷而非通话故障；引擎 MUST 记录日志并仍然持久化该事件
（fail-soft）。

当严格模式开启（环境变量 `ISALES_ENGINE_STRICT_TRANSCRIPT=1`，由引擎测试套件设置）
时，写时校验失败 MUST 抛出异常，使任何产出越界事件的测试失败（fail-fast）。

读取侧（`isales-api` `CallRecordRead`）的 `extra="forbid"` 严格校验 MUST 保持不变；
本要求在写入侧前移契约执行，MUST NOT 通过放宽读取侧来掩盖漂移。

#### Scenario: 合法事件正常写入

- **WHEN** 引擎对一个字段完全符合 `TranscriptEvent` 契约的事件调用 `append_event`
- **THEN** 事件通过校验，被追加到 `full_transcript`（必要时镜像进 `dialog_history`），无错误日志、无异常

#### Scenario: 越界事件在生产环境 fail-soft 并留痕

- **WHEN** 引擎在生产环境（`ISALES_ENGINE_STRICT_TRANSCRIPT` 未设为 `1`）写入一个违反 `TranscriptEvent` 契约的事件（如非法 literal 取值、越界 key、缺必填字段）
- **THEN** 引擎记录一条结构化 `transcript_event_schema_violation` 错误日志（含 `type` 与校验错误），且仍然持久化该事件，且**不**中断或结束当前通话

#### Scenario: 越界事件在严格模式（CI）fail-fast

- **WHEN** 在严格模式（`ISALES_ENGINE_STRICT_TRANSCRIPT=1`，引擎测试套件默认）下写入一个违反 `TranscriptEvent` 契约的事件
- **THEN** 引擎记录违例日志后抛出异常，使产出该事件的测试失败
