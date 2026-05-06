> 实施在 isales-engine 仓库（新建）。每组对应 1~2 个 PR，按顺序合入。
> 不动 isales-common（依赖 v0.1.2 即可）。

## 1. isales-engine 仓库骨架（PR #1）

- [ ] 1.1 `git init isales-engine` + `.gitignore`
- [ ] 1.2 `pyproject.toml`（hatchling）+ deps（isales-common>=0.1.2,<0.2、sqlalchemy[asyncio]、asyncpg、redis、httpx、pydantic、pydantic-settings、structlog）
- [ ] 1.3 dev 依赖（pytest / pytest-asyncio / ruff / mypy / types-redis / freezegun）
- [ ] 1.4 目录骨架（`isales_engine/{__init__,main,settings,db,redis_client,dial_consumer,event_publisher,event_consumer,session_manager,call_session,state_machine,transcript_recorder}.py` + `pipeline/{__init__,orchestrator,role_llm,judge_llm,polish_llm,json_parser,wrap_up_pipeline,greeting,prompt_builder}.py` + `realtime/{__init__,filler_manager,interruption_detector,silence_detector,no_progress_timer,telephony_client,mock_telephony}.py` + `transfer/{__init__,manager,intent_classifier}.py` + `wrapup/{__init__,manager}.py` + `providers/{__init__,factory,llm_mock,asr_mock,tts_mock}.py` + `tests/` + `scripts/`）
- [ ] 1.5 entry point `isales-engine`（`[project.scripts]`，调 `main:run`）
- [ ] 1.6 `settings.py`：pydantic-settings 读 `ISALES_DATABASE_URL` / `ISALES_REDIS_URL` / `ISALES_ENGINE_LLM_PROVIDER` / `ISALES_ENGINE_ASR_PROVIDER` / `ISALES_ENGINE_TTS_PROVIDER` / `ISALES_ENGINE_TELEPHONY_MODE` / `ISALES_ENGINE_MAX_NO_PROGRESS_SECONDS` / `ISALES_ENGINE_PIPELINE_DEFAULT_TIMEOUT_MS` / `ISALES_ENGINE_MOCK_CONNECT_DELAY_MS` / `ISALES_ENGINE_GRACEFUL_SHUTDOWN_TIMEOUT_S` / `TZ`
- [ ] 1.7 `db.py`（async session factory）+ `redis_client.py`（async redis client wrapper + `pubsub` factory）
- [ ] 1.8 `main.py`：lifespan 启动 `dial_consumer` task + `event_consumer.subscribe_loop` task + `session_manager`；SIGTERM handler → 优雅停机（停 dial 消费、cancel sessions、等 30s）
- [ ] 1.9 README + CI（ruff/mypy/pytest）— CI 装 isales-common @ v0.1.2 git tag

## 2. 状态机 + CallSession（PR #2）

- [ ] 2.1 `state_machine.py`：`CallState` 枚举（11 个状态）+ `LEGAL_TRANSITIONS: dict[CallState, set[CallState]]` + `IllegalTransition` 异常类
- [ ] 2.2 `state_machine.py`：`StateMachine.transition_to(new_state, reason, meta)` 改 state、写 `state_history`、抛 `IllegalTransition` 时同时让 CallSession append `state_error` 事件
- [ ] 2.3 `call_session.py`：`CallSession` dataclass（dialog_history / full_transcript / pipeline_trace_records / prompt_versions_snapshot / used_filler_phrase_ids_per_set / current_filler_set_index / silence_activation_count / silence_started_at / consecutive_interruption_count / wrap_up_round_count / wrap_up_started_at / current_turn_id / last_user_speech_end_at / last_tts_end_at / tasks dict / call_started_at）
- [ ] 2.4 `call_session.py`：`append_event(type, **fields)` 自动算 ts、按 transcript spec 决定是否进 dialog_history（仅 `greeting / user_speech / ai_reply` 进）+ type 枚举校验
- [ ] 2.5 `session_manager.py`：进程内 `dict[call_id, CallSession]` + `register / unregister / cancel_all / get`
- [ ] 2.6 `transcript_recorder.py`：通话 END 时事务批量写 `call_record(transcript=full_transcript, hangup_cause=..., ended_at=..., transfer_status=..., wrap_up_started_at=..., prompt_versions=...)` + N 条 `pipeline_trace`
- [ ] 2.7 测试：状态机所有合法转移路径全覆盖（INIT→GREETING→LISTENING→PROCESSING→SPEAKING→...→END）；非法转移抛 `IllegalTransition` + 写 `state_error`
- [ ] 2.8 测试：`append_event` 按 transcript spec § dialog_history 与 full_transcript 双集合的"系统话术不入 dialog_history"
- [ ] 2.9 测试：session_manager.register/unregister 幂等；cancel_all 等待所有 task 完成

## 3. DialRequest 队列消费 + DLQ + 并发计数器（PR #3）

- [ ] 3.1 `dial_consumer.py`：`dial_loop()` BLPOP `engine:dial`（timeout=1s）
- [ ] 3.2 用 isales-common `DialRequest` 反序列化；schema_version=1 支持，其他 → `LPUSH engine:dlq` + WARN 日志
- [ ] 3.3 单条消息：① 创建 CallSession（写入 prompt_versions snapshot 来自 DialRequest）→ ② session_manager.register → ③ 启动 state_machine（INIT 状态，启动 telephony_client.dial）
- [ ] 3.4 进 END 时：transcript_recorder.persist → `LPUSH engine:worker:call-ended`（用 isales-common `CallEnded`）→ `DECR isales:concurrency:active`（重试 3 次失败 ERROR 日志）→ session_manager.unregister → publish `EngineEvent.CallEnded`
- [ ] 3.5 异常路径：CallSession 创建 / state_machine 启动失败 → ERROR 日志、DECR + DLQ；不抛回 BLPOP 循环
- [ ] 3.6 测试：合法 DialRequest → CallSession 创建 + prompt_versions 写入 + INIT 转移 GREETING（mock telephony emit connected）
- [ ] 3.7 测试：schema_version=99 → DLQ；call_record 数据正确写入；并发计数器 DECR 一次
- [ ] 3.8 测试：DECR Redis 不可达 → 重试 3 次后 ERROR 日志，session 仍清理

## 4. Mock providers + provider factory（PR #4）

- [ ] 4.1 `providers/factory.py`：按 settings 选 LLM/ASR/TTS Provider；非 mock 全部 `NotImplementedError("stage 5: impl-engine-providers")`
- [ ] 4.2 `providers/llm_mock.py`：复用 `isales_common.providers.testing.MockLLMProvider`；扩展行为按 design § 20：关键字驱动确定性 JSON（默认 / 短回复 / 收尾 / 触发 goal_achieved / 裁判否决 / 润色拼接）
- [ ] 4.3 `providers/asr_mock.py`：`MockASRProvider` — `stream_recognize(audio_chunks)` 按 frame 节拍推 partial（每 200ms 一次）/ final；测试可注入"用户说话脚本"驱动
- [ ] 4.4 `providers/tts_mock.py`：`MockTTSProvider` — `synthesize_stream(text, voice_id)` 按文本长度生成 PCM 字节流（每字符 100ms）；输出 audio chunks + 标记播放完成
- [ ] 4.5 测试：MockLLM 关键字驱动各分支输出确定性
- [ ] 4.6 测试：MockASR 注入文本 → partial / final 序列时序符合预期
- [ ] 4.7 测试：MockTTS 文本 → PCM bytes 流 + duration 估算

## 5. MockTelephonyClient + audio 管道（PR #5）

- [ ] 5.1 `realtime/telephony_client.py`：ABC `TelephonyClient`（`dial(phone) -> str(call_id)` / `hangup(call_id)` / `audio_in(call_id) -> AsyncIterator[bytes]` / `audio_out(call_id, chunks: AsyncIterator[bytes])` / `events(call_id) -> AsyncIterator[TelephonyEvent]`）
- [ ] 5.2 `realtime/mock_telephony.py`：`MockTelephonyClient` 实现：dial → 异步等 `mock_connect_delay_ms` → emit `connected`；hangup → emit `local_hangup`；`simulate_remote_hangup`；`inject_user_audio(call_id, frames)` 测试 API
- [ ] 5.3 audio_in：用 asyncio Queue + 注入接口；audio_out：把 chunks 落 `_outbound_log[call_id]`（测试断言用）
- [ ] 5.4 测试：dial 流程 → connected 事件触发；remote_hangup / local_hangup 事件正确 emit
- [ ] 5.5 测试：注入用户 audio frames → audio_in 异步迭代器 yield 同样 frames
- [ ] 5.6 测试：audio_out 写入 → `_outbound_log` 累积
- [ ] 5.7 测试：abstract `tests/test_telephony_client_contract.py`（任何 TelephonyClient 实现都要通过的契约测试，留给阶段 6 RealTelephonyClient）

## 6. 三层并行管线 orchestrator（PR #6）

- [ ] 6.1 `pipeline/prompt_builder.py`：`build_role_messages(session, role_config, is_wrap_up, is_follow_up)` → system + user message 三段式（按 role-prompt spec）
- [ ] 6.2 `pipeline/json_parser.py`：`parse_role_output(text) -> ParseResult{reply, goal_achieved, goal_type, extracted, parse_failed}`：两步兜底（json.loads → 正则提取 → fallback）
- [ ] 6.3 `pipeline/role_llm.py`：`call_role(session, role_config, llm_provider) -> RoleCandidate{role_config_id, prompt_version_id, raw_output, parsed, duration_ms, tokens, error}`；超时 / Provider 异常 → error 字段填，candidate 标记 parse_failed
- [ ] 6.4 `pipeline/judge_llm.py`：`call_judge(judge_config, candidate_reply, llm_provider) -> JudgeResult{candidate_index, role_config_id, prompt_version_id, passed, reason, duration_ms}`；输入仅 reply 字段
- [ ] 6.5 `pipeline/polish_llm.py`：`call_polish(polish_config, passed_candidates, llm_provider) -> PolishResult{reply, selected_candidate_index, duration_ms, role_config_id, prompt_version_id, error}`；超时 / 异常 / JSON 错 → error
- [ ] 6.6 `pipeline/orchestrator.py`：`run_pipeline(session, user_input, campaign) -> PipelineOutcome{reply, goal_achieved, goal_type, extracted, selected_candidate_index, source: "polished"|"polish_fallback"|"default_reply"}`
  - 步骤：① N 路角色 `asyncio.gather` → ② 解析失败候选淘汰 → ③ N×M 路裁判 `gather` → ④ 全部否决 → 默认回复（写 `default_reply_used` transcript 事件）→ ⑤ 否则润色 → 失败 → 取通过裁判第一个候选兜底
  - 标记字段从被选中候选直接继承（不投票）
  - 全程累积 `PipelineTraceRecord`（含 `error` 字段）
- [ ] 6.7 `pipeline/wrap_up_pipeline.py`：`run_wrap_up(session, user_input, campaign) -> PipelineOutcome`：取 sort_order 最小的角色 + 润色，不 PK 不裁判
- [ ] 6.8 `pipeline/greeting.py`：`generate_greeting(campaign, lead, llm_provider) -> str`：固定模板 / LLM 单角色生成两路径；都不调裁判 / 润色
- [ ] 6.9 测试：N=2 角色 + M=1 裁判 全部通过 → 润色 → final reply 确定性
- [ ] 6.10 测试：单角色 JSON 解析失败 → 该候选淘汰、其余流程不变
- [ ] 6.11 测试：全部候选解析失败 → default_reply 兜底、写 transcript event
- [ ] 6.12 测试：全部裁判否决 → default_reply 兜底
- [ ] 6.13 测试：润色超时 / JSON 错 → 取通过裁判的第一个候选作为兜底（source=polish_fallback）
- [ ] 6.14 测试：标记字段不投票（候选 1 goal=true / 候选 2 goal=false → 润色选 1 → final goal=true；选 2 → false）
- [ ] 6.15 测试：每轮 PROCESSING 都写 pipeline_trace（成功 / 兜底 / 降级 / 异常 4 种路径全覆盖）
- [ ] 6.16 测试：开场白固定模板 / LLM 生成两路径，都进 dialog_history 都不调裁判 / 润色
- [ ] 6.17 测试：WRAPPING_UP 简化管线只调单角色 + 润色

## 7. filler_manager（PR #7）

- [ ] 7.1 `realtime/filler_manager.py`：`FillerManager(session, campaign, tts_provider, telephony_client)`，状态：`current_filler_set_index` / `used_phrase_ids_per_set`
- [ ] 7.2 `start(turn_id)`：根据当前轮号选 filler_set（按 sort_order 升序循环）→ 集内随机选未用 phrase（用完重置）→ 异步播 audio（如 audio_url 为空 / 下载失败 → 跳过）→ 写 `filler` transcript 事件
- [ ] 7.3 `stop()`：被打断时停 audio playback；不写已开始未完成的 filler 事件
- [ ] 7.4 `wait_finished()`：等 audio 播完
- [ ] 7.5 触发场景白名单：仅 PROCESSING 入口被 orchestrator 调用；GREETING 后第 1 轮 / WRAPPING_UP / TRANSFERRING / ACTIVATING / 收尾告别 都不调
- [ ] 7.6 测试：常规 PROCESSING 触发；GREETING 后第 1 轮不触发；WRAPPING_UP 不触发；TRANSFERRING 不触发
- [ ] 7.7 测试：3 个 filler_set 第 4 轮回 set#1；set 内不重复直至全部用完后重置
- [ ] 7.8 测试：管线先返回 → 等垫词播完才接 reply TTS（节奏一致）
- [ ] 7.9 测试：预生成未完成（generation_status=pending）跳过；OSS 下载失败跳过；全部 set 都没 ready → 整通不再尝试
- [ ] 7.10 测试：FILLER 期间打断 → 停垫词 + 丢弃当前 PROCESSING + 用 ASR 终态作为新一轮 PROCESSING

## 8. interruption_detector + silence_detector + no_progress_timer（PR #8）

- [ ] 8.1 `realtime/interruption_detector.py`：`InterruptionDetector(session, campaign)` — 订阅 ASR partial；判定 `text in whitelist OR (now - speech_start) < min_duration_ms`；满足 → 不打断；都不满足 → emit `interruption_triggered(asr_final_text)`
- [ ] 8.2 不可撤销：进 INTERRUPTED 后即使后续 partial 命中白名单也不回退
- [ ] 8.3 连续打断 counter：counter ≥ `max_continuous_interruptions` → 按 strategy（`short_reply` / `listen_only`）；完整轮次（无打断 SPEAKING 完成）counter 清零
- [ ] 8.4 `realtime/silence_detector.py`：`SilenceDetector(session, campaign)` — LISTENING 入口启 timer；起点 = max(speech_end, tts_end)；超 `silence_threshold_ms` → 触发激活
- [ ] 8.5 激活：`silence_phrases[i]`（i = 已激活次数；超数组复用最后一条）；ACTIVATING TTS 播完 → counter++ + 重置 timer 起点 = `last_tts_end_at = now`
- [ ] 8.6 上限：`silence_activation_count >= max_silence_activations` → 播 `silence_hangup_phrase` → END(reason=`silence_max_reached`)
- [ ] 8.7 激活话术写 `full_transcript`（type=`silence_activation`），MUST NOT 进 dialog_history
- [ ] 8.8 `realtime/no_progress_timer.py`：监测"用户一直说但都被判定非打断 / 无效内容"；超 `max_no_progress_seconds` → END(reason=`no_progress_timeout`)
- [ ] 8.9 测试：白名单完全等于不触发打断；时长 < 阈值不触发；命中触发 → 立即停 TTS + 状态 INTERRUPTED → PROCESSING（用 ASR 终态文本）
- [ ] 8.10 测试：连续打断 short_reply 策略 prompt 临时追加"请用一句话回应"；listen_only 策略 AI 说"您请说"
- [ ] 8.11 测试：完整轮次后 counter 清零
- [ ] 8.12 测试：FILLER 期间打断逻辑一致；WRAPPING_UP 期间打断后走简化管线
- [ ] 8.13 测试：沉默触发激活 → 计时起点 max(speech_end, tts_end)；激活上限挂断；话术不入 dialog_history
- [ ] 8.14 测试：转人工触发优先于沉默激活
- [ ] 8.15 测试：no_progress_timer 超时 → END(reason=no_progress_timeout)

## 9. transfer_manager + WRAPPING_UP manager（PR #9）

- [ ] 9.1 `transfer/intent_classifier.py`：mock 实现（按关键字返回 probability）；接口与 LLMProvider 兼容，阶段 5 接真
- [ ] 9.2 `transfer/manager.py`：`TransferManager(session, campaign, llm_provider)`：4 种触发独立 + OR 关系
  - keyword：ASR 终态结果包含 `transfer_keywords` 任一
  - intent：意图分类器输出概率 > `transfer_intent_threshold`
  - rounds：对话轮次 > `transfer_round_threshold` 且 goal_achieved=false
  - llm：独立判定 LLM 输出 `{"transfer": true}`
- [ ] 9.3 命中流程：状态 → TRANSFERRING；从 `transfer_phrases` 随机抽 1 → TTS 播完 → telephony_client.hangup → 写 `call_record.transfer_status='marked_for_handoff'` / `transfer_reason=<触发类型>` → END(reason=`marked_for_handoff`)
- [ ] 9.4 TRANSFERRING 期间：MUST NOT 调 AI 管线；ASR 继续仅补录 transcript；MUST NOT 二级分支
- [ ] 9.5 优先级：transfer > silence_activation > wrap_up
- [ ] 9.6 `wrapup/manager.py`：`WrapUpManager(session, campaign)`：润色返回 goal_achieved=true → 当前轮 SPEAKING 正常播完 → 进 WRAPPING_UP；写 `wrap_up_started_at = now`；轮数计数器 + 时长计数器；任一耗尽 → 播 `wrap_up_closing_phrases` 随机 → END(`wrap_up_completed`)
- [ ] 9.7 WRAPPING_UP 期间用户提新问题 / 反悔 → 走简化管线，MUST NOT 退主管线；用户主动挂机 → END(`user_hangup`)；转人工触发 → 让位
- [ ] 9.8 测试：4 触发独立路径 + OR 命中各组合（keyword 命中 / intent 命中 / rounds 命中 / llm 命中）
- [ ] 9.9 测试：TRANSFERRING 流程：衔接话术随机抽取、TTS 播完后挂断、call_record 字段写入
- [ ] 9.10 测试：TRANSFERRING 期间 ASR 继续补录 transcript（user_speech 事件）；不调 AI 管线
- [ ] 9.11 测试：WRAPPING_UP 入口：goal_achieved=true → 当前轮播完 → 进 WRAPPING_UP；写 wrap_up_started_at
- [ ] 9.12 测试：WRAPPING_UP 轮数耗尽 → 挂断；时长耗尽 → 挂断（freezegun 控时间）
- [ ] 9.13 测试：WRAPPING_UP 期间用户提新问题 → 简化管线响应 + 状态不退；反悔 → 同上
- [ ] 9.14 测试：WRAPPING_UP 期间转人工触发 → 让位走 TRANSFERRING

## 10. EngineEvent publish + EngineControl 消费（PR #10）

- [ ] 10.1 `event_publisher.py`：`EventPublisher(redis_client)` — `publish(event: EngineEvent)` fire-and-forget（`asyncio.create_task` + 内部 try/except）
- [ ] 10.2 各模块在状态转换 / ASR partial / ASR final / ai_reply / hangup / pipeline_completed 时调 publish；channel = `engine:events:campaign:{campaign_id}`
- [ ] 10.3 publish 内部 `asyncio.wait_for(timeout=2s)`；超时 / 异常 → WARN 日志
- [ ] 10.4 `event_consumer.py`：`subscribe_loop` PSUBSCRIBE `engine:control:campaign:*`，反序列化 `EngineControl`，按 `call_id` 在 session_manager 找 session 派发
- [ ] 10.5 `ManualHangup{call_id}` → 状态 → END(reason=`manual_hangup`)；`ForceTransfer{call_id}` → transfer_manager.start("manual")
- [ ] 10.6 不存在的 call_id → WARN 日志静默丢
- [ ] 10.7 测试：状态转换触发 publish 事件；publish 失败（Redis 不可达）不影响通话
- [ ] 10.8 测试：ASR partial / final / ai_reply / hangup 事件序列正确
- [ ] 10.9 测试：ManualHangup 找到 session → 进 END；不存在 call_id 静默丢

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
