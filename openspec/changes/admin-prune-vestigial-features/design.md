# Design — admin-prune-vestigial-features

本 change 是一次纯减法（删三个残废功能 + 修一个坏页）。设计层只有几处「删什么 / 留什么」的边界判断需要记录，避免误伤相邻功能，以及单迁移与枚举删除的安全性论证。

## Keep-vs-cut 边界判断

删一个功能最容易误伤的是与它共享标识符 / 字符串的相邻功能。下面逐条记录「看起来像该删、实则保留」的项及其理由：

| 项 | 决定 | 理由 |
|---|---|---|
| `goal_type="appointment"` 字符串标签 | **保留** | 这是 goal-achievement 的目标类型标签（「约到店」），是 routing_rules / call_summary 在用的独立特性，与被删的 `appointment` 台账表只是同名巧合，没有任何数据/代码耦合。删表不应动这个字符串。 |
| `campaign.voice_id` 列 | **保留** | 引擎 TTS 的音色来源。`voice_model` 删的是「编目」，不是「音色」；`f6a7b8c9d0e1`（2026-06-05）已把 voice_id 从 FK 改为自由文本串，引擎原样把它喂 TTS provider。删目录表不影响选音色。 |
| 引擎转人工**检测** | **保留** | 转人工能力本身（4 种触发 → 标 `transfer_status=marked_for_handoff` → 播衔接话术 → 主动挂断）完整保留。删的只是其**下游空表** handoff_task + 死字段，不是检测逻辑。 |
| `agent` 表 | **保留** | data-model 全表清单仍列 agent（v1 坐席登录主体）；handoff_task 是引用 agent 的子表，删子表不删父表。 |
| worker `lead.status=transferred` 信号 | **保留** | worker 收到 `transfer_status=marked_for_handoff` 的通话结束消息后仍标 `lead.status=transferred` + 命中 callback_config 时发 webhook；只是不再 insert handoff_task 行。 |
| `TransferTriggerType` 枚举 | **保留** | 转人工触发类型枚举，检测逻辑仍用，与被删的 `HandoffStatus`（任务状态枚举）是两件事。 |
| `LeadStatus.LOST` | **保留** | 只删 `APPOINTED` / `VISITED`（预约耦合成员）；LOST 是独立的「已流失」状态，与预约无关。 |

## 单一 drop 迁移

三张表（appointment / voice_model / handoff_task）由一条 alembic 迁移 `c4d5e6f7a8b9`（down_revision `b2f3a4c5d6e7`）一并 drop，而非每表一条。理由：三者同属「删残废后台功能」这一个语义单元、同一 change、同一发布；拆成三条迁移只会让 head 链多两跳而无任何回滚粒度收益（v1.0 无生产数据，回滚靠重建空表的 `downgrade()`，不靠分迁移）。`downgrade()` 按各表 create 迁移的 DDL 逐字重建三表，但**刻意不**恢复 campaign→voice_model 外键（该 FK 已在 `f6a7b8c9d0e1` 斩断，campaign.voice_id 现为 String(128)）——恢复它会与现行 schema 冲突。

## lead appointed/visited 枚举删除的安全性

`lead.status` 是 `String(16)` 列（非 PG enum），删 `LeadStatus.APPOINTED` / `VISITED` 两个 Python 枚举成员**无需 DB 迁移**：列本身不受枚举约束，删成员只影响应用层校验与 UI badge。v1.0 无生产数据，库里不存在 `status='appointed'` / `'visited'` 的历史行，删成员不会产生孤儿值。这与 data-model 既有「CallStatus 收缩无需 DB 迁移、历史行旧值为可接受孤儿」的同款论证一致。

## TransferMarkedEvent.handoff_task_id 死字段删除

`TransferMarkedEvent.handoff_task_id` 是消息契约里一个引擎 `run_loop.py` **从不填**的字段（转人工只标 + 挂断，从不创建 handoff_task，自然拿不到 id）。它和 `transcript` 的 `transfer_marked` 事件 `handoff_task_id` 字段是同一条死链路的两端。删字段后 `transfer_marked` 成为一个裸标记事件（只表示「衔接话术播完、已标记转人工」），消费方无需读 id。这是「多层兜底是问题味道」的对称应用：一个永不被写的字段不该长期挂在契约里。
