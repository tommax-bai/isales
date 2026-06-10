## 1. isales-common：schema union + 数据清洗 migration

<!-- e6f7a8b9c0d1 isales-common 0.8.7: +StateWarningEvent/+StateErrorEvent 入 union; data migration strip ai_reply.interrupted; AIReplyEvent 确认不含 interrupted -->
- [x] 1.1 `schemas/jsonb/transcript.py` 新增 `StateWarningEvent`（`type="state_warning"`, `attempted: str`, `from_state: str`, `to_state: str`，继承 `_BaseEvent`）
- [x] 1.2 同文件新增 `StateErrorEvent`（`type="state_error"`，同字段集），注释标注为历史事件名
- [x] 1.3 把 `StateWarningEvent` / `StateErrorEvent` 加入 `TranscriptEvent` discriminated union
- [x] 1.4 `AIReplyEvent` 保持不含 `interrupted`（确认无需改动，仅核对）
- [x] 1.5 新增 alembic data migration `e6f7a8b9c0d1`：遍历 `call_record.transcript` JSONB，对每个 `type='ai_reply'` 元素删除 `interrupted` key（幂等，仅改命中行，WITH ORDINALITY 保序）。alembic 单 head 确认
- [x] 1.6 bump `isales-common` 版本号 0.8.6 → 0.8.7
- [x] 1.7 `.venv` 跑 `pytest -q -k "transcript or migration or jsonb"` 18 passed；union 行为点验（state_warning/error 通过、ai_reply+interrupted 被拒）绿

## 2. isales-engine：删 interrupted 死字段 + state_changed 死代码

<!-- isales-engine: 删 4 处 ai_reply.interrupted + 删 state_changed 死分支/enum/meta 参数 + 更新 3 golden/contract/test_state_machine 测试; pin→0.8.7 -->
- [x] 2.1 `run_loop.py` 删除 4 处 `append_event("ai_reply", …, interrupted=…)` 的 `interrupted` 入参（1428/1446/1505/1656）
- [x] 2.2 核对：`_gated_trace` 的 `interrupted` 参数属 pipeline_trace 路径（且当前仅 ack 未写入 trace dict），与 transcript 无关，按设计保留不动
- [x] 2.3 `state_machine.py` 删除 `state_changed` 的 `append_event(..., **meta)` 分支 + 从 `call_session.py` 的 `TRANSCRIPT_EVENT_TYPES` 移除 `state_changed` + 移除 unused `Any` import
- [x] 2.4 `transition_to` 删除 `meta` 参数（生产零调用方）；更新 `tests/test_state_machine.py`（meta 用例改为断言不再 emit state_changed）+ `test_run_session_contract.py`（vocabulary 去 state_changed）+ 2 个 golden fixture 去 `interrupted` 行
- [x] 2.5 更新 `isales-common` pin `>=0.8.4` → `>=0.8.7,<0.9`
- [x] 2.6 `.venv` 装新 common 后 `pytest -q` 396 passed（1 failed=`test_gate_fails_open_to_main_on_referee_timeout` 经 git stash 验证为 pre-existing 时序竞态，与本改动无关）

## 3. isales-api：pin 对齐 + 读端验证

<!-- isales-api: pin→0.8.7 + 新增 TestTranscriptSchemaContract 回归(GET /calls 读含 state_warning 的 transcript=200 + ai_reply 含 interrupted 被 reject) -->
- [x] 3.1 更新 `pyproject.toml` 的 `isales-common` pin `>=0.8.4` → `>=0.8.7,<0.9`
- [x] 3.2 新增 `tests/test_calls_analytics.py::TestTranscriptSchemaContract`：(a) seed 含 `state_warning` 事件 + 无 `interrupted` 的 transcript → `GET /calls` 200 且读回 state_warning；(b) `CallRecordRead.model_validate` 对含 `interrupted` 的 ai_reply 抛 ValidationError（断言报错指向 interrupted）
- [x] 3.3 `.venv` 装新 common 后 `pytest -q tests/test_calls_analytics.py` 9 passed

## 4. 本地聚合验证

<!-- 关键子集绿: common 182 / engine 396(1 pre-existing gate flake) / api calls 9; worker 不经 schema 校验 transcript(opaque list 喂 summarize)、web 自有 TS 类型,均不受影响无需改 -->
- [x] 4.1 三仓 venv 装新 common 后关键子集绿（common schema 182 / engine transcript+contract+golden / api calls 9）；worker+web 经审计不消费 `TranscriptEvent` 契约，范围确认仅 common+engine+api
- [x] 4.2 `openspec validate fix-transcript-schema-drift --strict` 通过

<!-- 部署审计抓到第二处漂移: interruption.{rms,source,voice_active_ms} 历史数据(13+条),migration 扩展一并清洗(common a9a1c8f);全 scp 只带本 change 文件(并行 interruption-min-chars f7a8b9c0d1e2 隔离),alembic 显式 target e6f7a8b9c0d1 非 head -->
- [x] 5.1 scp 我的文件到 ECS（common transcript.py + migration e6f7a8b9c0d1；engine call_session/run_loop/state_machine）+ chown isales:isales；**刻意不带**并行 change 的 campaign/f7a8b9c0d1e2 文件
- [x] 5.2 先只读评估：170 条记录中 38 含 `ai_reply.interrupted` + 13 含 state_warning + 3 state_error + **0 state_changed**（证实判断）；全量审计另发现 13+ 条 `interruption` 带历史 VAD 字段 → migration 扩展清洗。`alembic upgrade e6f7a8b9c0d1`（显式 revision，避开并行未就绪的 f7a8b9c0d1e2）成功，after=0/0 违规行
- [x] 5.3+5.4 重启 isales-api+engine+scheduler+worker 全队列：4 服务 active，engine `isales_engine_started`+`credentials_loaded count=5`、api `Application startup complete`，0 error
- [x] 5.5 `/calls`→401（路由在+鉴权）、`/health`→200；重启后 api 日志 0 条 extra_forbidden/ValidationError
- [x] 5.6 **机器级全量校验取代浏览器点验**：用 `CallRecordRead.model_validate` 跑全部 170 条记录 → **170 PASS / 0 FAIL**（证明每条 transcript 都读得过，比单页 curl 更彻底）
- [x] 5.7 更新 `deploy/cloud/STATE.md`（本提交）

## 6. 收口

<!-- sub-repo commits: common 931b22b / engine e8dbd3d / api bd4bc48 — 均 push origin main -->
- [x] 6.1 各 sub-repo commit + push：isales-common `931b22b`、isales-engine `e8dbd3d`、isales-api `bd4bc48`（全 push origin main）
- [x] 6.2 meta-repo `tasks.md` 进度回写 + commit（本提交）
- [x] 6.3 `openspec validate --strict` 通过；delta 同步进 `specs/transcript/spec.md` 后 archive
