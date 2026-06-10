## Context

外呼记录页打不开是一个生产事故（`GET /calls` 整体 500）。三方契约出现漂移：

| 来源 | `ai_reply` 字段 | `state_warning`/`state_error` |
|---|---|---|
| 引擎实际写入（`call_session.append_event` 裸拼 dict，**不校验**） | 含 `interrupted`（4 处 append） | 写 `state_warning`（非法转移时） |
| `transcript` spec 事件枚举表 | 不含 `interrupted` | 未登记 |
| `call-state-machine` spec | — | 明确要求写入 transcript |
| `isales-common` `TranscriptEvent` union（`extra="forbid"`） | `AIReplyEvent` 无 `interrupted` | union 无这两类 |

读端 `isales-api` 的 `CallRecordRead.transcript: list[TranscriptEvent]` 用 `model_validate` 逐条校验，任一越界字段/未知事件类型即 `ValidationError` → `list_calls` 500。引擎写库路径（`transcript_recorder.py:94` 把整个 `full_transcript` 原样灌进 `call_record.transcript`）不做校验，所以坏数据顺利落库，到读端才爆。

## Goals / Non-Goals

**Goals:**
- 让外呼记录页对**存量 + 增量**数据都能打开（`GET /calls` 不再 500）。
- 消除 transcript 写端（引擎）与读端契约（common schema + transcript spec）的全部已知漂移。
- 遵循「去根因、不堆兜底层」：删死字段而非给读端加 `extra="allow"` 兜底。

**Non-Goals:**
- 不重构 `append_event` 使其在写入时做 Pydantic 校验（更大改动，单列 followup）。本 change 仅对齐契约。
- 不改 `GET /calls` 的分页/查询逻辑。
- 不引入 transcript schema 版本化机制。

## Decisions

### D1：`ai_reply.interrupted` 走「删字段 + 清存量」（方向 B），不走「补进 schema」（方向 A）

- **选择**：引擎 4 处 `append_event("ai_reply", …)` 删 `interrupted` 入参；对生产库做一次性数据清洗剥掉已写入的 key。
- **理由**：该字段全链路（worker/api/web）grep 确认**无人消费**；打断信息已由独立 `interruption` 事件（`interrupted_event_id`/`user_text_at_interruption`）+ `pipeline_trace`（`_gated_trace(..., interrupted=...)`）承载，是冗余只写数据。transcript spec line 118 还要求「restructure 对 ai_reply payload 透明、结构 MUST NOT 改变」——把 ai_reply 收回到 spec 定义的字段集才是正解。
- **Alternatives**：方向 A（把 `interrupted` 加进 `AIReplyEvent` + spec）。否决：会把无人消费的死字段固化进契约，违反 spec 的 payload-稳定要求，且留下技术债。用户已在选项中明确选 B。

### D2：`state_warning` / `state_error` 走「补进 union」，不删

- **选择**：`TranscriptEvent` union 新增 `StateWarningEvent` + `StateErrorEvent`（`attempted` / `from_state` / `to_state` + 继承 `ts`）。
- **理由**：与 D1 相反，这两个事件是 `call-state-machine` spec **明确要求写入 transcript** 的（spec line 41/125/169/184-194）。`state_warning` 引擎当前真在写（非法转移），`state_error` 为历史事件名（DB 存量可能有，spec 要求消费方识别）。它们是合法 transcript 事件，缺的是 common schema——补 schema 才是去根因。

### D3：`state_changed` 去掉 `**meta` spread 死代码，不进 union

- **选择**：`state_machine.py` 的 `state_changed` 分支生产无任何调用方传 `meta`（仅 `tests/test_state_machine.py:179` 传），去掉 `**meta` spread；从引擎 `TRANSCRIPT_EVENT_TYPES` 移除 `state_changed`；删该 append 分支；更新对应单测。union 不加 `StateChangedEvent`。
- **理由**：`**meta` 把任意 key spread 进事件，与读端 `extra="forbid"` 天然冲突——是「一旦有人接 meta 调用就会复现本次事故」的潜在层。生产从不写入 `state_changed`，存量 DB 不可能含它，删除零数据风险。符合「多层兜底/死代码是问题味道，删掉根因」。
- **Alternatives**：把 meta 收进 `meta: dict` 子字段并加 `StateChangedEvent`。否决：为一个零生产调用的分支增加契约面，不值当。

### D4：数据清洗用 JSONB 原地 UPDATE，幂等

- **选择**：`UPDATE call_record SET transcript = <strip interrupted from each ai_reply element>` —— 遍历 transcript 数组、对 `type='ai_reply'` 的元素删 `interrupted` key。用 SQL 表达式（jsonb 操作）一次完成，可重复执行（key 不存在则无操作）。
- **理由**：存量记录不清洗则读回仍 500。幂等保证可安全重跑。
- **落地形态**：放入 `isales-common` 的一个 alembic data migration（与 schema 版本同节奏发布），ECS 上 `alembic upgrade head` 即应用；亦可手工跑等价 SQL 作为热修。

## Risks / Trade-offs

- **[存量数据清洗遗漏其他越界字段] → Mitigation**：清洗前先在库里 `SELECT` 统计 transcript 中出现过的 `ai_reply` 字段集 + 全部 `type` 值，确认除 `interrupted` 外无其他越界项；本 change 的 union 增补（state_warning/error）覆盖已知的事件类型缺口。
- **[引擎与 api 版本不同步窗口] → Mitigation**：部署顺序 = 先发 `isales-common`（含新 union + data migration）→ 部署 api（读端先能容旧+新数据）→ 部署 engine（写端停写 interrupted）→ 跑 data migration 清存量。读端先放宽再清洗，全程不产生新的不可读数据。
- **[生产库写操作] → Mitigation**：data migration 幂等、仅删冗余 key、不改其他字段；先 `SELECT count(*)` 评估影响行数；RDS 有自动备份兜底。
- **[删 state_changed 影响未来需求] → Mitigation**：当前零生产调用；若未来确需状态变更明细事件，按 spec 流程新增带显式字段的事件类型即可，不依赖 `**meta`。

## Migration Plan

1. `isales-common`：改 union（+2 event 类）、bump 版本、新增 data migration（strip `ai_reply.interrupted`）。`alembic heads` 确认 revision 不撞。
2. `isales-api`：更新 `isales-common` pin，本地 `make test-all` 子集验证。
3. `isales-engine`：删 4 处 `interrupted` 入参 + `state_changed` 死代码 + 更新单测；更新 `isales-common` pin。
4. ECS 部署：scp 覆盖 → 先 common+api（`alembic upgrade head` 跑数据清洗）→ engine → `systemctl restart`。
5. 真机点验：浏览器打开外呼记录页确认列表正常渲染 + 展开某条通话 transcript 正常。
6. **Rollback**：data migration 仅删冗余 key 不可逆但无害；如读端异常可临时回滚 api 到旧 common pin（旧 schema 仍能读清洗后的数据，因为清洗只是去掉了它本就不认识的字段）。

## Open Questions

- data migration 是否需对 `pipeline_trace` 列做同类审计？（初判 trace 是引擎自有结构、api 用独立 `PipelineTrace` schema 读，且本次报错仅在 transcript；apply 阶段顺手 grep 确认 trace schema 与引擎写入一致即可，不扩大本 change 范围。）
