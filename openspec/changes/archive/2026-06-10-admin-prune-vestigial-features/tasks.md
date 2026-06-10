# Tasks — admin-prune-vestigial-features

实装与单测已在本 session 完成（标 `[x]` 并附 HTML 注释说明）；部署到 ECS 与 archive 尚未做（留 `[ ]`）。

**Commits (2026-06-09, all on `main`):** isales-common `3bd1815` · isales-engine `1c7ef2e` · isales-api `b2db404` · isales-web `b720473` · meta-repo = this commit. 未推送前缀状态见各仓 `git log`。

## isales-common

- [x] 删 `Appointment` 模型 + schema、`AppointmentStatus` / `AppointmentAction` 枚举 <!-- isales-common: delete Appointment model + schemas + AppointmentStatus/AppointmentAction enums -->
- [x] 删 `VoiceModel` 模型 + schema <!-- isales-common: delete VoiceModel model + schema; campaign.voice_id String column untouched -->
- [x] 删 `HandoffTask` 模型 + schema、`HandoffStatus` 枚举 <!-- isales-common: delete HandoffTask model + schema + HandoffStatus enum; agent table + TransferTriggerType kept -->
- [x] 删 `LeadStatus.APPOINTED` / `VISITED` 成员（保留 `LOST`） <!-- isales-common: drop LeadStatus.APPOINTED/VISITED only; LOST kept; String(16) column → no DB enum migration -->
- [x] 删 `TransferMarkedEvent.handoff_task_id` 死字段 <!-- isales-common: drop handoff_task_id from TransferMarkedEvent (engine run_loop.py never wrote it) -->
- [x] drop 迁移 `c4d5e6f7a8b9`（down_rev `b2f3a4c5d6e7`），drop appointment / voice_model / handoff_task 三表 + 索引 <!-- isales-common: alembic c4d5e6f7a8b9 drops 3 tables + indexes; downgrade re-creates structurally, NOT the severed campaign->voice_model FK -->
- [x] 版本 0.8.4 → 0.8.5 <!-- isales-common: pyproject version = 0.8.5 -->
- [x] 单测全绿 <!-- isales-common: 182 tests green -->

## isales-engine

- [x] `run_loop.py` 不再写 `handoff_task_id`（转人工检测 + 标记 + 主动挂断照旧） <!-- isales-engine: TransferMarkedEvent emitted without handoff_task_id; detection/mark/hangup unchanged -->
- [x] 单测全绿 <!-- isales-engine: tests green -->

## isales-api

- [x] 删 appointment router 及注册 <!-- isales-api: remove appointments router + include_router -->
- [x] 删 voice_model router 及注册 <!-- isales-api: remove voice-models router + include_router -->
- [x] 删 handoff_task GET-only router 及注册 <!-- isales-api: remove handoff-tasks router + include_router -->
- [x] lead 状态去 APPOINTED/VISITED 耦合 <!-- isales-api: drop appointed/visited from lead status validation + filters -->
- [x] 单测全绿 <!-- isales-api: tests green -->

## isales-web

- [x] 删预约 view（`/appointments`）+ `CreateAppointmentDialog`（外呼记录创建入口） <!-- isales-web: remove Appointments view + CreateAppointmentDialog + appointment api + route -->
- [x] 删音色目录 view / 组件 / api <!-- isales-web: remove VoiceModelList view + components + voiceModels api + route -->
- [x] 删转人工任务死页 <!-- isales-web: remove HandoffTaskList dead page + route -->
- [x] TopNav 主入口五→四（场景/线索/外呼/数据看板），「更多」折叠区去音色目录/转人工任务 <!-- isales-web: TopNav 5→4 main entries, drop 预约; 更多 drawer drops 音色目录 + 转人工任务 -->
- [x] 修节假日页（Page-vs-array 绑定 bug + 加创建/删除 UI） <!-- isales-web: HolidayList bind res.items not Page object + add create/delete UI; backend unchanged, no spec delta -->
- [x] vitest 全绿 <!-- isales-web: vitest green -->

## meta-repo（spec + 根文档）

- [x] `appointment` spec delta：REMOVED 5 条 + ADDED 1 条 tombstone「预约能力已下线」（openspec 不允许空 spec，故 capability 保留为下线声明） <!-- meta: specs/appointment/spec.md REMOVED 5 + ADDED tombstone; archive 时 rebuilt spec 必须 ≥1 requirement -->
- [x] `human-handoff` spec delta：MODIFIED「TRANSFERRING 流程」(worker 只标 transferred，不写 handoff_task) + REMOVED「坐席工作流」 + Data Schema 删 handoff_task 行 <!-- meta: specs/human-handoff -->
- [x] `data-model` spec delta：MODIFIED 全表清单（删 3 行 + lead 去 appointed/visited） <!-- meta: specs/data-model -->
- [x] `web-admin-ui` spec delta：MODIFIED TopNav + view 清单（删 3 入口） <!-- meta: specs/web-admin-ui -->
- [x] `transcript` spec delta：MODIFIED 事件枚举（transfer_marked 去 handoff_task_id） <!-- meta: specs/transcript -->
- [x] `provider-abc` spec delta：MODIFIED voice_id 改 campaign.voice_id vendor 串 <!-- meta: specs/provider-abc -->
- [x] 根文档同步：DESIGN.md 删 appointment capability 索引行 <!-- meta: DESIGN.md remove 预约 index row (line 38) -->
- [x] `openspec validate admin-prune-vestigial-features --strict` 通过 <!-- meta: validate passes zero errors -->

## 部署 + archive（未做）

- [x] 跨仓部署到 ECS：scp editable 源码（common/engine/api）+ rm 删除文件 + 清 pycache + chown → `alembic upgrade b2f3a4c5d6e7 → c4d5e6f7a8b9`（drop 3 表）→ 重启 engine+api+scheduler+worker → web build+rsync+nginx；STATE.md 已更 <!-- deployed 2026-06-10 10:05 CST; ECS alembic head c4d5e6f7a8b9; pg_dump 兜底 admin-prune-vestigial-20260610-100029.sql（三表 row count 全 0）; web backup web-admin-prune-20260610-100337.tgz -->
- [x] ECS smoke（机器级全绿）：/voice-models·/appointments·/handoff-tasks→404、/holidays·/calls→401、/health→200、openapi 无 vestigial path、公网 SPA 200、4 服务 restart clean（0 error）、engine run_loop `marked_for_handoff` 仍在 <!-- 真机拨号验转人工 + 浏览器点验节假日增删 deferred：机器级证据充分（路由消失/表 drop/服务 clean/转人工码在），比照 interruption-rule-editor「浏览器点验 waived，机器验证为据」archive 惯例 -->
- [ ] `/opsx:archive admin-prune-vestigial-features`（合并 spec delta 到 openspec/specs/，移入 archive/）
