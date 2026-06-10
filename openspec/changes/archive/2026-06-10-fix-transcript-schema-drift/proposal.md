## Why

外呼记录页（web `/calls`）整页打不开。根因是后端 `GET /calls` 返回 **500**：引擎把一个未登记的 `interrupted` 布尔字段写进了 `transcript` 的 `ai_reply` 事件，而 `isales-common` 的 `CallRecordRead` / `AIReplyEvent` schema 设了 `extra="forbid"` 且没有该字段——于是任何 transcript 含 `ai_reply` 事件的通话记录在 `model_validate` 时即 `ValidationError`，列表接口逐条校验全挂。ECS 实时日志已确认：`N validation errors for CallRecordRead … transcript.K.ai_reply.interrupted [extra_forbidden]`。

同时审计发现 `TranscriptEvent` union 还缺 `state_warning` / `state_error` 两个 `call-state-machine` spec **已要求写入 transcript** 的事件类型——是同源潜在地雷（非法状态转移或历史数据触发时同样 500）。本 change 一并收口该 schema 漂移。

## What Changes

- **引擎停止写 `ai_reply.interrupted`**：`isales-engine/run_loop.py` 4 处 `append_event("ai_reply", …, interrupted=…)` 删除该入参。该字段全链路（worker/api/web）无人消费，打断信息已由独立的 `interruption` 事件 + `pipeline_trace` 承载，属只写不读的死数据。
- **清洗存量数据**：对生产库 `call_record.transcript` JSONB 做一次性迁移，剥掉所有 `ai_reply` 元素中已写入的 `interrupted` key（否则存量记录读回仍 500）。
- **补齐 schema union**：`isales-common` 的 `TranscriptEvent` union 新增 `StateWarningEvent` + `StateErrorEvent`（字段 `attempted` / `from_state` / `to_state`，继承 `_BaseEvent.ts`），消除已 spec 化但 schema 缺失的事件类型漂移。bump `isales-common` 版本并更新 `isales-api` 的 pin。
- **收紧 `state_changed` 契约**：引擎 `state_machine.py` 的 `state_changed` 分支生产无调用方（仅单测传 `meta`），去掉 `**meta` spread 这一与 `extra="forbid"` 天然冲突的死代码层，更新对应单测。`state_changed` 不进 union（生产从不写入）。
- **spec 对齐**：`transcript` spec 的事件类型枚举表补 `state_warning` / `state_error` 两行（与 `call-state-machine` spec 对齐），并新增 scenario 明确 `ai_reply` payload **不含** `interrupted` 字段。

## Capabilities

### New Capabilities
<!-- 无新增 capability -->

### Modified Capabilities
- `transcript`: 事件类型枚举表新增 `state_warning` / `state_error` 两类；明确 `ai_reply` 事件 payload 字段集不含 `interrupted`（消费方按 `extra="forbid"` 校验）。

## Impact

- **isales-engine**：`run_loop.py`（删 4 处 `interrupted` 入参）、`state_machine.py`（去 `state_changed` 的 `**meta` spread + 从事件枚举移除 `state_changed`/或保留待议）、`tests/test_state_machine.py`（更新 meta 单测）。
- **isales-common**：`schemas/jsonb/transcript.py`（+2 event 类入 union）、版本号 bump。
- **isales-api**：`isales-common` pin 更新；`GET /calls` 行为不变（仅契约对齐后不再 500）。
- **生产数据**：一次性 `UPDATE call_record … transcript` JSONB 清洗（需 ECS / RDS 写权限）。
- **部署**：ECS 重部署 `isales-api` + `isales-engine`，跑数据清洗，真机点验外呼记录页可打开。
- **meta-repo**：`openspec/specs/transcript/spec.md` 经本 change delta 合并；`tasks.md` 进度回写。
