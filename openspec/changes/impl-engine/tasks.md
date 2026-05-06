> 实施在 isales-engine 仓库（新建）。每组对应 1~2 个 PR，按顺序合入。
> 不动 isales-common（依赖 v0.1.2 即可）。

## 1. isales-engine 仓库骨架（PR #1）

- [x] 1.1 `git init isales-engine` + `.gitignore`
- [x] 1.2 `pyproject.toml`（hatchling）+ deps（isales-common>=0.1.2,<0.2、sqlalchemy[asyncio]、asyncpg、redis、httpx、pydantic、pydantic-settings、structlog）
- [x] 1.3 dev 依赖（pytest / pytest-asyncio / ruff / mypy / types-redis / freezegun）
- [x] 1.4 目录骨架（`isales_engine/` + `pipeline/` + `realtime/` + `transfer/` + `wrapup/` + `providers/` + `tests/` + `scripts/` + `deploy/`；后续 PR 增量加文件）
- [x] 1.5 entry point `isales-engine`（`[project.scripts]`，调 `main:run`）
- [x] 1.6 `settings.py`：pydantic-settings 读全部 `ISALES_*` env（含队列名 / 通道名常量化）
- [x] 1.7 `db.py`（async session factory）+ `redis_client.py`（复用 isales-common get_redis）
- [x] 1.8 `main.py`：lifespan 骨架 + SIGINT/SIGTERM handler + stop_event；后续 PR 加 dial_consumer / event_consumer / session_manager task
- [x] 1.9 README + 3 个 smoke 测试；ruff / mypy / pytest 全绿（CI 在 PR #14 一并接入）

## 2. 状态机 + CallSession（PR #2）

- [x] 2.1 `state_machine.py`：`CallState` (= isales_common CallStatus) + `LEGAL_TRANSITIONS` 全图 + `IllegalTransition`
- [x] 2.2 `state_machine.py`：`StateMachine.transition_to(new_state, reason, meta, force)` — 写 state_history、非法时 append state_error + 抛异常；force=True 跳过校验
- [x] 2.3 `call_session.py`：CallSession dataclass 含全部 spec 列表的字段（dialog_history / full_transcript / pipeline_trace_records / 三个 counter / wrap_up / turn_id / last_user_speech_end_at / last_tts_end_at / tasks / 时间锚点）
- [x] 2.4 `call_session.py`：`append_event(type, **fields)` 自动 ts、type 枚举校验、dialog_history 路由（仅 greeting/user_speech/ai_reply）
- [x] 2.5 `session_manager.py`：register / unregister / get / active_count / cancel_all（async with asyncio.timeout）
- [x] 2.6 `transcript_recorder.py`：`persist_call_record` 事务批量写 call_record + N 条 pipeline_trace；3 次指数退避；失败仅 ERROR 日志
- [x] 2.7 测试：状态机所有合法路径 + 非法转移抛 + 写 state_error + force=True 跳过 + 终态 END 无出度
- [x] 2.8 测试：append_event 路由（filler / silence_activation 不入 dialog_history）+ 未知 type 抛
- [x] 2.9 测试：register 幂等 / unregister / cancel_all 等待 finalizer

## 3. DialRequest 队列消费 + DLQ + 并发计数器（PR #3）

- [x] 3.1 `dial_consumer.py`：`dial_loop()` BLPOP `engine:dial`（timeout=1s）+ `handle_dial` 单条处理
- [x] 3.2 schema_version 不支持 / JSON 错 / Pydantic ValidationError → `LPUSH engine:dlq` + WARN 日志
- [x] 3.3 合法消息：reserve_call_record（INSERT call_record）→ 构造 CallSession（含 prompt_versions snapshot）→ register → 起 fire-and-forget 任务
- [x] 3.4 END flow（call_lifecycle.finalize_session）：persist → LPUSH CallEnded → DECR `isales:concurrency:active` → unregister；每步独立重试 + 日志
- [x] 3.5 runner_with_finalize：runner 异常 / 取消时 finalize 仍跑完（asyncio.shield 包 finalize）；hangup_cause 兜底
- [x] 3.6 测试：happy path → CallSession 创建 + persist + LPUSH CallEnded + DECR 正确 + session unregister
- [x] 3.7 测试：schema_version=99 / JSON 错 / ValidationError 三类 → DLQ
- [x] 3.8 测试：runner 抛 / runner 取消 → finalize 仍执行；CallEnded payload 形状校验；finalize_session 直接调用

## 4. Mock providers + provider factory（PR #4）

- [x] 4.1 `providers/factory.py`：build_llm/asr/tts；非 mock NotImplementedError
- [x] 4.2 `providers/llm_mock.py`：KeywordDrivenMockLLM — 按 system tag（[role]/[judge]/[polish]/[transfer_intent]/[transfer_llm]）+ user 关键字（成功/预约 / **reject** / do_not_call / 转人工）驱动；json_mode=False 时贴解释性前后缀以便测试 regex 兜底
- [x] 4.3 `providers/asr_mock.py`：ScriptedMockASR + feed_turn(text) API；每 partial_step_ms 一个 partial + 最后 final
- [x] 4.4 `providers/tts_mock.py`：TextLengthMockTTS — 字符 × pcm_bytes_per_char 输出 PCM
- [x] 4.5 测试：MockLLM role/judge/polish/transfer 各分支确定性
- [x] 4.6 测试：ScriptedMockASR partial/final 序列正确
- [x] 4.7 测试：MockTTS PCM 字节数与文本长度成比例

## 5. MockTelephonyClient + audio 管道（PR #5）

- [x] 5.1 `realtime/telephony_client.py` ABC + `TelephonyEvent`（connected / local_hangup / remote_hangup / device_error）
- [x] 5.2 `realtime/mock_telephony.py` MockTelephonyClient：dial 内联 emit connected（delay=0）/ 异步 task（delay>0）；hangup / simulate_remote_hangup；inject_user_audio
- [x] 5.3 audio_in / audio_out 用 asyncio.Queue + outbound_log
- [x] 5.4 测试：connected / local / remote hangup 事件序列
- [x] 5.5 测试：inject_user_audio → audio_in yield 同样 frames
- [x] 5.6 测试：audio_out 累积到 outbound_log
- [x] 5.7 `tests/test_telephony_client_contract.py` parametrize fixture，stage 6 加 RealTelephonyClient 时一行注册

## 6. 三层并行管线 orchestrator（PR #6）

- [x] 6.1 `pipeline/prompt_builder.py`：三段式 user message + system 末尾按状态追加 WRAPPING_UP / 跟进 / short_reply 段落
- [x] 6.2 `pipeline/json_parser.py`：parse_role_output 两步兜底；parse_judge_output 失败默认 passed=False；parse_polish_output 失败返回 (None,None)
- [x] 6.3 - 6.5 角色 / 裁判 / 润色调用合并到 orchestrator._call_roles_parallel / _run_judges_parallel / _call_polish（per-call 超时 + 异常包成 error 字段）
- [x] 6.6 `pipeline/orchestrator.py`：run_pipeline 完整 PROCESSING；标记字段从选中候选直接继承不投票；4 类 source（polished / polish_fallback / default_reply / wrap_up_simplified）；error 字段
- [x] 6.7 wrap-up 简化管线通过 `is_wrap_up=True` 复用 run_pipeline（取 roles[:1]，不裁判）；wrap_up_simplified 标识
- [x] 6.8 `pipeline/greeting.py`：固定模板 / LLM 单角色，不裁判不润色
- [x] 6.9-6.17 测试：18 个 pytest 全绿，覆盖 happy path / appointment 触发 / 全部裁判否决 / 全部解析失败 / 润色失败兜底 / 标记字段不投票 / pipeline_trace 4 路径 / 角色超时 / wrap-up 简化 / greeting 三种模式

## 7. filler_manager（PR #7）

- [x] 7.1 `realtime/filler_manager.py` FillerManager + FillerSetSpec / FillerPhraseSpec
- [x] 7.2 start：按 sort_order + id 排稳定 round-robin 选 set；集内随机不重复（用完重置）；non-ready set 自动跳过
- [x] 7.3 stop：CancelledError 干净停；被打断时不写 filler 事件
- [x] 7.4 wait_finished
- [x] 7.5 触发场景白名单留给 PR #11 的 CallSession.run() 调用控制（filler_manager 仅做 "选 + 播 + 停"）
- [x] 7.6 测试：no-ready 跳过 / ready 写 filler 事件
- [x] 7.7 测试：3 set × 2 phrase × 7 轮 round-robin 顺序 + 集内 dedup
- [x] 7.8 等垫词播完接 reply 由 PR #11 主流程负责（filler_manager 提供 wait_finished）
- [x] 7.9 测试：generation_status=pending → set 跳过；audio_url 缺失 → 跳过
- [x] 7.10 测试：stop 取消 + 不写事件（覆盖被打断场景）+ idempotent start

## 8. interruption_detector + silence_detector + no_progress_timer（PR #8）

- [x] 8.1-8.3 `realtime/interruption_detector.py` evaluate_partial(text, speech_started_ts_ms, now_ts_ms, config)；不可撤销 + 连续打断 counter 由 PR #11 主循环维护
- [x] 8.4-8.7 `realtime/silence_detector.py` silence_calc_origin_ts + evaluate_silence；wait / activate(phrase) / hangup 三种决策
- [x] 8.8 `realtime/no_progress_timer.py` is_no_progress_exceeded（None / 0 禁用）
- [x] 8.9-8.15 13 个 pytest 覆盖：whitelist / 阈值 / trigger / 边界；silence 起点 max + 三种话术-上限关系 + hangup；no_progress 边界与 disable。FILLER / WRAPPING_UP / 优先级等场景互动留给 PR #11 整合测试

## 9. transfer_manager + WRAPPING_UP manager（PR #9）

- [x] 9.1 intent / llm 触发都通过 LLMProvider（无独立 IntentProvider ABC）；KeywordDrivenMockLLM 的 [transfer_intent] / [transfer_llm] 系统标签分发
- [x] 9.2 `transfer/manager.py` evaluate_transfer 4 类独立 + OR 短路（keyword → round → intent → llm 顺序）；trigger_detail 含命中证据
- [x] 9.3 TRANSFERRING 流程主串联（TTS → hangup → call_record 字段）由 PR #11 调用 evaluate_transfer 后驱动
- [x] 9.4-9.5 不调管线 + 优先级也由 PR #11 主循环负责
- [x] 9.6 `wrapup/manager.py` evaluate_wrap_up 双计数器（轮数 + 时长）；空 closing 兜底
- [x] 9.7 用户行为响应（提问 / 反悔 / 挂机 / 转人工让位）由 PR #11 主循环组合 evaluate_wrap_up + evaluate_transfer 实现
- [x] 9.8-9.14 13 个 pytest 覆盖：transfer 8 路径（无触发 / 4 类触发 / 两个边界 / OR 短路）；wrapup 5 路径（proceed / 轮数耗尽 / 时长耗尽 / 边界 / 兜底）

## 10. EngineEvent publish + EngineControl 消费（PR #10）

- [x] 10.1 `event_publisher.py` EventPublisher.publish 起子任务 + drain 等所有 inflight
- [x] 10.2 PUBLISH 通道 engine:events:campaign:{campaign_id}；publish 调用点由 PR #11 主流程在状态转换 / ASR / hangup 等时机插入
- [x] 10.3 内部 2s asyncio.timeout；超时 / 异常 WARN 日志
- [x] 10.4 `event_consumer.subscribe_loop` PSUBSCRIBE engine:control:campaign:* + TypeAdapter[EngineControl] discriminated union 反序列化
- [x] 10.5 派发 ManualHangup / TransferCommand 到注入 handler（hangup 与 transfer 的具体进 END / TRANSFERRING 流程由 PR #11 提供 handler）
- [x] 10.6 不存在 call_id / 无效 payload → WARN + silently dropped
- [x] 10.7-10.9 6 个 pytest 覆盖：发布与订阅 / 不阻塞主流程 / ManualHangup 派发 / 未知 call_id / 无效 payload / TransferCommand 派发

## 11. 主流程串联：DialRequest → 完整通话 → CallEnded（PR #11）

- [ ] 11.1 `call_session.py`：`run()` 主协程：
  1. 启 telephony_client.dial → 等 connected → state INIT → GREETING → 播 greeting → state GREETING → LISTENING
  2. 启 silence_timer / no_progress_timer
  3. 用户 speech_start / speech_end loop：speech_end → state LISTENING → PROCESSING + filler 启动 + orchestrator.run_pipeline
  4. PROCESSING 完成：goal_achieved=true → state SPEAKING（播当前轮 reply）→ 等 TTS 完 → wrap_up_manager.start()；否则 state SPEAKING → 等 TTS 完 → state LISTENING
  5. WRAPPING_UP 内部 loop：用户说话 → wrap_up_pipeline.run；轮数 / 时长任一耗尽 → 挂断
  6. 各种挂断路径 → state END → finally 块写 DB / LPUSH CallEnded / DECR / unregister / publish
- [ ] 11.2 finally 块：try/except 包裹每一步（DB 写失败重试 3 次 / Redis 失败重试 3 次）；最终失败仍执行 unregister 防泄漏
- [ ] 11.3 `dial_consumer` 把 DialRequest 派发给 `call_session.run()`（独立 asyncio.task）
- [ ] 11.4 测试：端到端 5 轮 mock 对话（用 fake_dial 注入 + MockASR 脚本驱动）→ goal_achieved=true → WRAPPING_UP 2 轮 → END → DB / `engine:worker:call-ended` 队列写入校验
- [ ] 11.5 测试：MockTelephony simulate_remote_hangup → END(reason=`user_hangup`) + 各 finally 块都跑
- [ ] 11.6 测试：10 路并发 mock 通话（10 个 fake_dial 同时跑）→ 每路独立 + 并发计数器准确进退（INCR 由 fake_dial 模拟、DECR 由 engine）

## 12. fake_dial 注入脚本（PR #12）

- [ ] 12.1 `scripts/fake_dial.py`：argparse `--db-url` `--redis-url` `--campaign-id` `--lead-id?` `--phone-number?` `--voice-model-id?` `--mock-asr-script <yaml>` `--simulate-hangup-after-seconds?`
- [ ] 12.2 装载 YAML：`{events: [{at_seconds: 1, asr_partial: "你"}, {at_seconds: 2, asr_final: "你好"}, ...]}`
- [ ] 12.3 可选自动建 lead（如未指定）；查 prompt_versions snapshot from DB
- [ ] 12.4 构造 DialRequest（schema_version=1）→ INCR `isales:concurrency:active` → `LPUSH engine:dial`
- [ ] 12.5 注：mock ASR 脚本由测试时 monkeypatch MockTelephonyClient 注入（不在脚本本身内驱动 ASR）；脚本仅注入 DialRequest，让 engine 跑起来
- [ ] 12.6 不在 `[project.scripts]` 暴露；仅 `python -m scripts.fake_dial`
- [ ] 12.7 测试：脚本注入 → engine 从 BLPOP 拿到 → CallSession 创建（用 in-process 启动一个 engine 实例做 smoke test）

## 13. 优雅停机 + systemd unit + 部署文档（PR #13）

- [ ] 13.1 `main.py` SIGTERM handler：① 停 dial_consumer task → ② session_manager.cancel_all（每个 session 给 30s 完成时间）→ ③ 等所有 task 完成（带 `ISALES_ENGINE_GRACEFUL_SHUTDOWN_TIMEOUT_S` 上限，默认 30s，超时强制 SIGKILL）
- [ ] 13.2 cancel 时给每个 session 写 `hangup{reason="engine_shutdown"}` 事件 + 走完整 finally 块（写 DB / LPUSH CallEnded / DECR）
- [ ] 13.3 `deploy/isales-engine.service`：systemd unit + hardening flags（PrivateTmp / ProtectSystem 等）；`Restart=on-failure`；`TimeoutStopSec=35`；EnvironmentFile 加载共享密钥
- [ ] 13.4 README 部署章节：env 表（与 isales-api / scheduler / worker 共享 PG / Redis）+ alembic upgrade 由 isales-common 包跑（engine 不跑 alembic）+ journalctl
- [ ] 13.5 IMPLEMENTATION_PLAN.md 阶段 4 验收清单全部勾选
- [ ] 13.6 测试：SIGTERM → 所有 active session 被 cancel + 写 hangup{engine_shutdown} + DECR + LPUSH CallEnded
- [ ] 13.7 测试：超时（30s 内 session 没退出）→ 强制结束（暂用 timeout 较短的测试模式，如 1s）

## 14. 收尾

- [ ] 14.1 全量 pytest 全绿（含 telephony_client_contract 测试）
- [ ] 14.2 mypy / ruff 无 error
- [ ] 14.3 端到端验收：用 `fake_dial.py` 注入一条 → 完整 5 轮 mock 对话 → goal_achieved=true → WRAPPING_UP → END → DB（call_record / pipeline_trace / transcript JSONB）+ Redis（`engine:worker:call-ended` 队列 1 条 + `isales:concurrency:active` 净增 0）正确
- [ ] 14.4 端到端验收：10 路并发 fake_dial → engine 全部接 → DB 10 条 call_record + 队列 10 条 CallEnded + 并发计数器净增 0
- [ ] 14.5 端到端验收：用 isales-api 的 `/campaigns/{id}/start` + scheduler 起来 → 真 DialRequest 派发 → engine 接管 → worker 收 CallEnded（前提 scheduler / worker 已部署）
- [ ] 14.6 主仓 commit 标记 impl-engine 实施完成；archive 由 /opsx:archive 触发
