# 清理三个残废后台功能 + 修节假日页（admin-prune-vestigial-features）

## Why

后台沉淀了三个**残废功能**——它们或没有任何运行时生产者/消费者、或编目层早被切断只剩孤儿表，纯粹给单角色 IA 添堵；同期发现节假日页存在绑定 bug、缺增删 UI。审计（git log + 运行时代码路径）逐一确认其残废性后，一次性端到端删除并修页。

1. **预约（appointment）— 纯手工台账，无运行时闭环**。`appointment` 表只能从「外呼记录」手动点「创建预约」对话框写入，engine / scheduler / worker **无任何生产者或消费者**；它顺带把 lead 状态机污染出 `APPOINTED` / `VISITED` 两个只有该功能在用的成员。这是一套与 AI 外呼主链路无关的独立小台账，留着只会让单角色工作流多一个无产出入口。

2. **音色目录（voice_model）— 编目层早被切断的孤儿表**。`voice_model` 表本是 campaign 选音色的编目，但 2026-06-05 的迁移 `f6a7b8c9d0e1` 已把 `campaign.voice_id` 从外键改为自由文本串（引擎 TTS 直接原样消费 vendor speaker 串），目录与 campaign 之间的外键早已斩断。`voice_model` 自此是无人引用的孤儿表 + 一个无后端意义的后台编目页。

3. **转人工任务（handoff_task）— write-never 表**。引擎的转人工**检测**仍在（命中即标 `transfer_status=marked_for_handoff` 并主动挂断），但 `handoff_task` 表**从未被写入过**：worker 只发 `lead.status=transferred` 信号，从不 insert handoff_task 行；它的 api router 是 GET-only、web 是死页、`TransferMarkedEvent.handoff_task_id` 字段引擎 `run_loop.py` 也从不填。这是一张设计了坐席工作流但 v1 衰减后再没接线的空表。

4. **节假日页（holidays）坏了**。前端把分页 `Page` 对象当数组绑定导致渲染异常，且缺少创建 / 删除 UI。后端行为不变（scheduler 仍正常消费 holiday 表），仅修前端，**无 spec 改动**。

**明确保留、未删除**（避免误伤相邻功能）：

- `goal_type="appointment"` 字符串标签——这是 goal-achievement 的「目标类型=约到店」标签，与已删的预约台账是两件事；routing_rules 仍用它。
- `LeadStatus.LOST`——只删 `APPOINTED` / `VISITED` 两个预约耦合成员。
- `campaign.voice_id` 自由文本列——引擎 TTS 的音色来源，原样保留。
- 引擎转人工**检测**（标记 + 挂断）、worker `lead.status=transferred` 信号、`TransferTriggerType` 枚举、`agent` 表——转人工能力本身不动，只删那张从没被写过的 handoff_task 表 + 死页 + 死字段。

## What Changes

把三个残废功能**端到端**删除，并修节假日页。代码与测试已实装通过，本 change 收口 spec + 根文档。

1. **预约 — 整体删除**。删 `appointment` 表（drop 迁移 `c4d5e6f7a8b9`）、`Appointment` 模型 / schema、`AppointmentStatus` / `AppointmentAction` 枚举、`LeadStatus.APPOINTED` / `VISITED` 成员、api router、web view + `CreateAppointmentDialog`（外呼记录创建入口）+ lead 的 APPOINTED/VISITED 状态耦合。`appointment` capability spec 整体清空（REMOVED 全部 requirement）。

2. **音色目录 — 整体删除**。删 `voice_model` 表（同一迁移）、`VoiceModel` 模型 / schema、api router、web view / 组件 / api。保留 `campaign.voice_id` 自由文本列。

3. **转人工任务 — 删空表 + 死字段**。删 `handoff_task` 表（同一迁移）、`HandoffTask` 模型 / schema、`HandoffStatus` 枚举、GET-only api router、死 web 页、死字段 `TransferMarkedEvent.handoff_task_id`（引擎 `run_loop.py` 不再写它）。`human-handoff` spec 改 worker 只标 `lead.status=transferred`（命中 callback_config 才发 webhook，**不**写 handoff_task）、删「坐席工作流」requirement、从 Data Schema 删 handoff_task 行（保留 agent 行 / campaign.transfer_* / call_record.transfer_status/reason / 4 种触发 / TRANSFERRING 话术挂断）。

4. **节假日页修复**。Page-vs-array 绑定 bug 修正 + 加创建 / 删除 UI。无 spec 改动。

5. **单一 drop 迁移**。三张表 + 索引由一条 alembic 迁移 `c4d5e6f7a8b9`（down_revision `b2f3a4c5d6e7`）一并 drop；isales-common 版本 0.8.4 → 0.8.5。

## Impact

- **Specs**：`appointment`（清空，REMOVED 全部）、`human-handoff`（worker 不再写 handoff_task + 删坐席工作流 + Data Schema 删 handoff_task 行）、`data-model`（全表清单删 appointment / voice_model / handoff_task 三行 + lead 状态去 appointed/visited，保留 agent 行 / campaign.voice_id requirement / goal_type='appointment' 路由示例）、`web-admin-ui`（TopNav 删预约 / 音色目录 / 转人工任务三入口，主入口五→四）、`transcript`（`transfer_marked` 事件不再带 `handoff_task_id`，成裸标记事件）、`provider-abc`（`voice_id` 改为 `campaign.voice_id` 的 vendor speaker 串，不再是 voice_model.voice_id）。
- **Code**：
  - `isales-common`：删 `Appointment` / `VoiceModel` / `HandoffTask` 模型 + schema、`AppointmentStatus` / `AppointmentAction` / `HandoffStatus` 枚举、`LeadStatus.APPOINTED` / `VISITED` 成员、`TransferMarkedEvent.handoff_task_id` 字段；drop 迁移 `c4d5e6f7a8b9`；版本 0.8.4 → **0.8.5**。
  - `isales-engine`：`run_loop.py` 不再写 `handoff_task_id`（转人工检测 + 标记 + 挂断照旧）。
  - `isales-api`：删 appointment / voice_model / handoff_task 三个 router 及其注册；lead 状态去 APPOINTED/VISITED 耦合。
  - `isales-web`：删预约 view + `CreateAppointmentDialog` + 音色目录 view/组件/api + 转人工任务死页；TopNav 主入口五→四 + 「更多」折叠区去音色目录/转人工任务；修节假日页（Page 绑定 + 增删 UI）。
- **DB 迁移**：单条 drop 迁移 `c4d5e6f7a8b9`（down_rev `b2f3a4c5d6e7`），drop `appointment` / `voice_model` / `handoff_task` 三表 + 索引；v1.0 无生产数据，drop 安全。
- **版本 bump**：isales-common 0.8.4 → 0.8.5；下游 api / engine / worker pin 在 `>=0.8,<0.9` 范围内，无需改 pin 约束、reinstall 即可。
- **跨仓部署序**：common（发 0.8.5）→ api / engine / worker reinstall common + `alembic upgrade head`（跑 drop 迁移）→ web。先升后端再跑迁移再上 web，避免 web 引用已删 api 端点的窗口。
- **行为影响**：纯减法 + 修页。AI 外呼主链路、转人工检测、scheduler 节假日消费均不变；删的三表 v1.0 无生产数据。
