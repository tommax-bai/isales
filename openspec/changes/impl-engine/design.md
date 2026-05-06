## Context

阶段 4 的 isales-engine 实施。spec 已经在 `architecture` / `call-state-machine` / `ai-pipeline` / `role-prompt` / `goal-achievement` / `filler` / `interruption-detection` / `silence-activation` / `human-handoff` / `transcript` / `service-communication` / `message-contract` / `provider-abc` 中描述。impl-scheduler（已归档）已经在 `engine:dial` 队列里推 `DialRequest`；impl-worker（已归档）已经在 `engine:worker:call-ended` 队列等 `CallEnded`；impl-api（已归档）已经在 `engine:events:campaign:{id}` Pub/Sub 上 fan-out `EngineEvent`，并在 `engine:control:campaign:*` 上 publish `EngineControl`。本 change 把这四条管道接通——但 v1 阶段 4 不接真 LLM/ASR/TTS（阶段 5），不接 modem-controller IPC 与真实硬件（阶段 6）。

约束：

- Python 3.11+，与 isales-common / api / scheduler / worker 一致
- 全 asyncio（与其他四个服务一致）
- 单实例部署（v1 单主机 ≤8 路并发；engine 多实例 v2 候选）
- 阶段 4 真实硬件未接：本 change MUST 提供进程内 `MockTelephonyClient` + mock providers，让端到端 5 轮对话 / 打断 / 沉默激活 / 转人工 / 兜底 / 润色降级 / WRAPPING_UP 全套验收能脱离阶段 5/6 独立完成
- 不动 isales-common（v0.1.2 已含全部需要的 model / messages / Provider ABC / Mock Provider）

## Goals / Non-Goals

**Goals:**

- 消费 `engine:dial` 队列；按 DialRequest 创建 CallSession 并启动状态机
- 状态机覆盖 call-state-machine spec 全部 11 个状态与转移路径
- 三层并行管线（N 路角色 PK + N×M 裁判 + 1 润色）+ JSON 解析两步保护 + 全部裁判否决兜底 + 润色失败降级
- 实时行为模块：filler（含多 set 轮询 + 集内不重复 + 触发场景白名单 + 失败跳过）/ interruption-detector（双条件 + 不可撤销 + 连续打断保护）/ silence-detector（计时起点 + 激活上限 + 话术不入 dialog_history）/ no_progress_timer
- 转人工 4 触发独立可配 + OR 关系 + 标记 + 主动挂断（不实时桥接）
- WRAPPING_UP 双计数器（轮数 + 时长）+ 简化管线 + 收尾期间特殊行为
- prompt_versions snapshot：CallSession 初始化时一次性写入 call_record
- transcript 三段式存储：通话事件流 → call_record.transcript（JSONB）；管线 trace → pipeline_trace 表；录音留 NULL（阶段 6 写）
- 进 END 时落 call_record / pipeline_trace / 派 CallEnded / DECR 并发计数器
- EngineEvent / EngineControl Pub/Sub 双向接通
- MockTelephonyClient + Mock Provider 全套，阶段 4 完全脱离阶段 5/6 单测
- `scripts/fake_dial.py` 让阶段 4 独立验收
- pytest 全绿：状态机所有路径 + 三层管线全场景 + filler/interruption/silence 各 spec scenario + 转人工 4 触发 + 收尾双计数器 + EngineEvent/Control + 10 路并发 + 优雅停机

**Non-Goals:**

- 不实现真 LLM/ASR/TTS Provider（阶段 5 的 `impl-engine-providers` change）
- 不实现 modem-controller IPC 客户端（`telephony_client.py` 仅含 ABC + MockTelephonyClient；阶段 6 的 `impl-engine-hardware` change 加 `RealTelephonyClient`）
- 不实现录音上传（recording_url v1 由 modem-controller 阶段 6 写；本 change 仅落 NULL）
- 不实现 handoff_task 创建（worker 阶段 3B 已在 marked_for_handoff 时由 worker 创建——本 change 仅写 `call_record.transfer_status` / `transfer_reason`）
- 不实现 engine 多实例部署（单实例够，v2 候选）
- 不实现 dialog_history 长度截断 / 摘要（按 role-prompt spec § 对话过长不做截断）
- 不实现 PII 脱敏（按 transcript spec § PII 脱敏 v1 不做）
- 不实现意图分类器真实模型（本 change mock 一个 stub；阶段 5 与 LLM Provider 一并接真）
- 不实现独立判定 LLM 真实接入（v1 mock；阶段 5 与其他 LLM 一并接真）
- 不实现 dialog_history 跨通话续接（每通独立；跟进通话靠 scheduler 派发的 `last_call_summary` 注入 user message）
- 不实现 max_continuous_interruptions 之外的"打断保护"扩展（如降级到完全静音）

## Decisions

### 1. 全 asyncio + 进程内 SessionManager；不引入跨进程协议

- **选择**：DialRequest 消费、CallSession、状态机、所有 Provider、MockTelephonyClient、event publisher、control consumer 都跑在同一个 asyncio event loop；SessionManager 是进程内 dict
- **理由**：
  - 与 api / scheduler / worker 一致；引入 multiprocessing 多一层进程边界，调试 / 监控复杂度激增，单实例下没有收益
  - v1 ≤8 路并发，单 event loop 完全够（每路通话主要是网络 I/O 等 LLM/ASR/TTS）
  - SessionManager 跨实例分布是 v2 议题（候选：sticky session via Redis hash slot）；本 change 不涉及
- **替代**：multiprocessing per session → 太重；single event loop 加 worker pool → asyncio 已足够

### 2. CallSession 是状态 + 全部 timer + 全部上下文的承载点

- **选择**：单个 dataclass-like class，持有：
  - `state: CallState`（11 个枚举之一）+ `previous_state` + `state_history`（用于调试）
  - `dialog_history: list[DialogTurn]`（喂角色 LLM；不含 silence/filler/transfer/wrap_up_started 等系统话术）
  - `full_transcript: list[TranscriptEvent]`（写 DB；包含全部事件）
  - `pipeline_trace_records: list[PipelineTraceRecord]`（每轮 PROCESSING 一条）
  - `prompt_versions_snapshot: dict`（启动时填，固化）
  - `used_filler_phrase_ids_per_set: dict[int, set[int]]`（filler 集内不重复记录）
  - `current_filler_set_index: int`（多 set 轮询游标）
  - `silence_activation_count: int` + `silence_started_at: float | None`
  - `consecutive_interruption_count: int`
  - `wrap_up_round_count: int` + `wrap_up_started_at: float | None`
  - `current_turn_id: int`（每轮 PROCESSING +1）
  - `last_user_speech_end_at: float | None` + `last_tts_end_at: float | None`（计算沉默起点）
  - `tasks: dict[str, asyncio.Task]`（current_pipeline / filler / silence_timer / no_progress_timer / tts_playback ...）
- **理由**：把所有需要在状态机各模块间共享的东西集中在一处，避免到处传递；测试时构造一个 CallSession 即可注入所有上下文
- **替代**：每模块自己持状态 → 状态散落，事件路由难写；用 `contextvars` → 隐式依赖，调试痛

### 3. 状态机：统一 `transition_to(state, reason, meta)` API + 非法转移抛异常 + 立即写 transcript

- **选择**：`StateMachine.transition_to(new_state, reason, meta)` 是唯一改 state 的入口；内部维护 `LEGAL_TRANSITIONS: dict[CallState, set[CallState]]`；非法转移 → 抛 `IllegalTransition`、写 transcript `state_error`；外层调用方 `try` 包裹决定是忽略 / 强制进 END
- **理由**：
  - call-state-machine spec 要求所有状态转换都走统一事件驱动 API、转换时往 transcript 追加事件
  - 非法转移在测试中早暴露；运行时容错 + 调试便利两不误
- **替代**：状态机用第三方库（`transitions` / `python-statemachine`）→ 多一层依赖、callback API 表达力差；所有模块自由改 state → 不可维护

### 4. 三层管线：每轮 PROCESSING 写一条 pipeline_trace；失败也写

- **选择**：orchestrator 在每轮 PROCESSING 入口创建 `PipelineTraceRecord(call_record_id, turn_id, ts_start, ...)`；进入兜底 / 降级 / 异常路径时仍累积字段并写库（`error` / `final_selected_candidate_index=-1` 等）；写 pipeline_trace 用独立 try/except 包裹，失败仅 ERROR 日志，不影响通话
- **理由**：
  - transcript spec § pipeline_trace 字段约束要求"每轮"都写
  - 调试三层管线必须有 trace，没 trace 出问题查不出
- **替代**：仅成功路径写 → 兜底 / 降级路径丢失现场；同事务写 call_record + pipeline_trace → 持锁太久

### 5. 三层管线：候选不等满，"任一返回即送下一层"——两阶段分别并行 vs 串行

- **选择**：
  - Layer 1（角色 PK）：`asyncio.gather(N 路角色调用, return_exceptions=True)` 等所有完成（无超时下限就用 `ISALES_ENGINE_PIPELINE_DEFAULT_TIMEOUT_MS` 单角色级超时）；spec 写"至少有 1 个候选成功即立即传 Layer 2"，但 spec 并没硬性要求 Layer 2 不等剩余角色——v1 简化为 Layer 1 全部完成（包括超时 / 异常返回 ProviderError）后再去 Layer 2，避免"先得到候选先送审 vs 再得到候选再送审"的竞态导致 pipeline_trace 字段顺序不稳定
  - Layer 2（裁判）：对每个解析成功的候选起 M 路裁判，全部并行 `gather` 等所有完成（通过裁判的候选集合 = 全部 M 个 passed=true）
  - Layer 3（润色）：单次调用，超时 / 异常 / JSON 错 → 取通过裁判的第一个候选作为兜底
- **理由**：
  - ai-pipeline spec § "至少有 1 个候选成功即立即传 Layer 2" 是为了优化延迟；但 v1 ≤8 路并发，每个 LLM 8s 超时，串行等满足后再 Layer 2 的额外延迟在最坏情况是 1 个 LLM 的尾延迟（通常 < 2s），可接受
  - 早送 Layer 2 实现复杂（要追踪 N 个 future 的 done/pending、要在 Layer 2 进行中能动态加入新候选）；v1 不上这个复杂度
- **替代**：
  - 早送 Layer 2 → 实现复杂，pipeline_trace 字段顺序难规整
  - 单角色 Layer 1（不 PK）→ 违反 ai-pipeline spec § N 个角色 LLM 并行调用

### 6. 三层管线：标记字段不投票

- **选择**：润色返回 `selected_candidate_index`（润色 prompt 里要求输出）；orchestrator 用 `roles[selected].goal_achieved/goal_type/extracted` 作为最终值；润色 LLM **MUST NOT 输出** 自己的标记字段
- **理由**：goal-achievement spec § 润色对标记的处理 + § 三层管线对结构化标记的处理；单角色误报由 prompt 设计 + 收尾对话兜底，不在润色层投票
- **替代**：N 个候选 goal_achieved 多数投票 → 违反 spec；润色自己输出标记 → 容易"跑偏"，与候选解耦

### 7. JSON 解析：两步兜底 + 失败候选直接淘汰

- **选择**：`pipeline/json_parser.py:parse_role_output(text) -> ParseResult`：
  1. `json.loads(text)` → 成功 + 字段齐全 → 返回 `{reply, goal_achieved, goal_type, extracted}`
  2. 失败 → 正则 `re.search(r'\{.*\}', text, re.DOTALL)` 提取 → 再 `json.loads`
  3. 再失败 → `ParseResult(parse_failed=True, fallback_reply=<整段 text>, ...)`；该候选在 orchestrator 层直接淘汰（等同被裁判否决，spec § 角色 LLM JSON 解析失败的处理）
- **理由**：role-prompt spec § JSON Mode 强制策略（两步保护）；mock LLM 输出可能包含围绕 JSON 的解释性前后缀，正则兜底更鲁棒
- **替代**：用 `pydantic.TypeAdapter.validate_json` → 严格但一旦失败无 fallback；要求 LLM 必须严格 JSON → 真 LLM 阶段 5 出问题就破

### 8. role-prompt 三段式 user message + WRAPPING_UP / 跟进段落追加

- **选择**：`pipeline/role_llm.py` 内拼装 user message：
  ```
  [跟进段落（可选）]【上次通话纪要】<scheduler 注入的 last_call_summary>

  【线索信息】name=<...>, phone=<...>, custom_data=<...>

  【对话】
  AI: <greeting 或 ai_reply>
  用户: <user_speech>
  AI: <ai_reply>
  ...
  AI:
  ```
  system message 在原始 prompt 末尾按 role-prompt spec 追加：跟进段落（仅 follow_up_count > 0）+ 收尾段落（仅 WRAPPING_UP）
- **理由**：role-prompt spec § Prompt 三段式组装、§ 收尾期间在 system prompt 末尾追加指令、§ 跟进通话的 prompt 增强
- **替代**：用 chat completion 多轮 messages → 违反 spec § 不使用标准 chat multi-turn

### 9. filler：与管线**同时启动**；多 filler_set 按 sort_order 升序循环；集内随机不重复

- **选择**：`filler_manager.start(turn_id)` 与 `orchestrator.run_pipeline()` 在 PROCESSING 入口并行；filler manager 自己跑 audio 播放 task；管线返回 reply 后调 `await filler_manager.wait_finished()` 再启 reply TTS
- **理由**：filler spec § 启动时机与衔接、§ 多 filler_set 轮询、§ 集合内随机不重复
- **替代**：先等管线再播垫词 → 违反 spec § 快响应场景；不维护已用集合 → 同通电话连续重复同一短语

### 10. interruption_detector：双条件 + 不可撤销 + 连续打断 counter

- **选择**：在 SPEAKING / FILLER 状态订阅 ASR `partial` 事件；每次 partial 来都判定 `text in whitelist OR (now - speech_start) < min_duration_ms` → 任一为 True 则不打断；都 False 一次即立即停 TTS / 停 filler、状态 → INTERRUPTED → PROCESSING（用 ASR 终态文本）；INTERRUPTED 进入后即使后续 partial 命中白名单也不回退
- **理由**：interruption-detection spec § 双条件、§ 不可撤销、§ 连续打断保护；不可撤销简化状态机
- **替代**：可撤销 → 状态机指数级复杂；只看时长 → 简单但用户嗯嗯就被截

### 11. silence_detector：计时起点是 max(speech_end, tts_end)

- **选择**：在 LISTENING 入口启 silence_timer：起点 = max(`session.last_user_speech_end_at`, `session.last_tts_end_at`)；超 `silence_threshold_ms` → 进 ACTIVATING；ACTIVATING 中播 `silence_phrases[i]`（i = `silence_activation_count`，超数组长度复用最后一条），TTS 播完后 `silence_activation_count++` + 重置 timer 起点为 `last_tts_end_at = now`
- **理由**：silence-activation spec § 沉默检测与激活触发、§ 激活后重新计时、§ 话术顺序使用与超限复用
- **替代**：起点固定为 LISTENING 进入时刻 → 不符合 spec（spec 要求 max(speech_end, tts_end)）

### 12. transfer_manager：4 触发独立 + OR 关系 + 优先级最高

- **选择**：在 LISTENING 进入 PROCESSING 前 / SPEAKING 收 ASR final 时检查 4 触发；任一命中即 → TRANSFERRING；TRANSFERRING 优先于 silence_activation 与 wrap_up；衔接话术随机 + 主动挂断后写 `call_record.transfer_status / transfer_reason` + END(reason=`marked_for_handoff`)
- **理由**：human-handoff spec § 4 种独立触发机制、§ TRANSFERRING 流程、§ 与状态机的交互
- **替代**：触发优先级倒挂 → 用户在收尾时说要转人工就被忽略，违反 spec

### 13. WRAPPING_UP：进入触发是当前轮**润色后**返回 goal_achieved=true；当前轮 reply 正常播完再切

- **选择**：orchestrator 返回 `PipelineOutcome(goal_achieved=true, reply, ...)` → 状态 → SPEAKING（正常 TTS）→ TTS 播完 → `wrap_up_manager.start()` → 状态 → WRAPPING_UP；写 `call_record.wrap_up_started_at = now`；WRAPPING_UP 期间 PROCESSING 调 `wrap_up_pipeline.run`（单角色 + 润色）；轮数 / 时长任一耗尽 → 播 `wrap_up_closing_phrases` 随机 → END(`wrap_up_completed`)
- **理由**：goal-achievement spec § 进入 WRAPPING_UP 状态、§ 收尾双计数器与主动挂断、§ 收尾期间的特殊情况处理
- **替代**：goal_achieved=true 立即挂断 → 违反 spec § 当前轮回复正常播放

### 14. EngineEvent publish：fire-and-forget；publish 失败不影响通话

- **选择**：`event_publisher.publish(event)` 是 `asyncio.create_task(self._do_publish(event))`；`_do_publish` 内部 try/except 全捕，失败 WARN 日志；不阻塞主路径
- **理由**：service-communication spec § 队列与 Pub/Sub 的边界（Pub/Sub 用于"实时、可丢失"事件）；通话主路径不能因为 Redis 一次 PUBLISH 慢而卡
- **替代**：同步 publish + 失败抛 → 通话主路径被网络抖动卡

### 15. EngineControl 消费：单 SUBSCRIBE 任务 + dispatch 给 SessionManager

- **选择**：启动一个 `event_consumer.subscribe_loop()` task：`PSUBSCRIBE engine:control:campaign:*`，反序列化 `EngineControl`，按 `call_id` 在 SessionManager 找 session 并派发指令；不存在的 call_id → WARN 日志静默丢
- **理由**：service-communication spec § api→engine Pub/Sub
- **替代**：多 task per campaign → 跨 campaign 控制开销大；HTTP 接口 → 违反 spec § 内部 HTTP 仅用于设备选择

### 16. CallEnded 派发与 DECR 并发原子性

- **选择**：进 END 时按顺序：① 写 `call_record`（含 transcript / hangup_cause / ended_at / transfer_status / wrap_up_started_at）+ 写 N 条 pipeline_trace（在同一事务内 commit）→ ② `LPUSH engine:worker:call-ended` 一条 CallEnded → ③ `DECR isales:concurrency:active` → ④ session_manager.unregister(call_id) → ⑤ publish `EngineEvent.CallEnded` 给 api
- **理由**：worker 拿到 CallEnded 必须能找到 call_record；DB 提交后再 LPUSH 保证因果；DECR 在 LPUSH 后避免"DB 没写完 scheduler 又派一通进来填上空位"
- **替代**：DECR 在 DB 之前 → scheduler 抢占空位时 worker 还查不到 call_record；同事务 DECR + LPUSH → Redis / PG 不在同一事务

### 17. 优雅停机：cancel + 写 hangup{engine_shutdown} + DECR

- **选择**：`main.py` 注册 SIGTERM handler：① 停 DialRequest 消费 task（不再起新 session）→ ② 给所有 active session 发 `transition_to(END, reason='engine_shutdown')` → ③ session 内部 finally 块写 call_record + LPUSH CallEnded + DECR → ④ 等所有 task 完成（带 30s 超时）→ ⑤ 进程退出
- **理由**：service-communication spec § 防计数器泄漏；不写 hangup 事件 → DB 留半截；不 DECR → scheduler 后续派发被并发上限堵
- **替代**：硬 kill → DB / Redis 状态不一致；不超时 → 卡死

### 18. MockTelephonyClient：进程内事件队列 + 测试注入

- **选择**：`telephony_client.py` 暴露 `TelephonyClient` ABC（`dial(phone) -> str(call_id)` / `hangup(call_id)` / `audio_in() -> AsyncIterator[bytes]` / `audio_out(chunks: AsyncIterator[bytes])` / `events() -> AsyncIterator[TelephonyEvent]`）；`MockTelephonyClient` 实现：
  - dial → 异步等 `mock_connect_delay_ms` → emit `connected` event
  - hangup → emit `local_hangup` event；停所有内部 task
  - audio_in：从测试注入的 `inject_user_audio(call_id, frames)` 队列消费
  - audio_out：把 chunks 落到 `_outbound_log[call_id]`（测试断言用）
  - `simulate_remote_hangup(call_id)` → emit `remote_hangup`
- **理由**：阶段 4 不接真硬件，必须有可控 mock；阶段 6 加 `RealTelephonyClient` 时业务代码 0 改动
- **替代**：用 modem-controller 的 mock IPC server → 引入跨进程，调试 / 单测复杂

### 19. 队列 / 通道名约定

- 消费 / 写入与已部署服务一致：
  - `engine:dial`（消费 BLPOP，scheduler 写入）
  - `engine:worker:call-ended`（生产 LPUSH，worker 消费）
  - `engine:events:campaign:{campaign_id}`（生产 PUBLISH，api fan-out）
  - `engine:control:campaign:*`（消费 PSUBSCRIBE，api 写入）
  - `engine:dlq`（生产，schema 不兼容 dead letter）
  - `isales:concurrency:active`（DECR）
- 不引入额外队列（如 inter-engine session migration）

### 20. mock LLM 行为细节：用 prompt 关键字驱动确定性输出

- **选择**：`MockLLMProvider`（isales-common v0.1.2 已含基本版本）按 prompt 关键字返回不同 JSON：
  - 无特殊关键字 → 默认 `{"reply": "好的，请稍等", "goal_achieved": false, "goal_type": "", "extracted": {}}`
  - 含「请用一句话回应」（连续打断 short_reply 策略）→ 返回单句 reply
  - 含「目标已达成」（WRAPPING_UP 收尾段落）→ `{"reply": "好的，期待和您再次联系，再见。", "goal_achieved": false, "goal_type": "", "extracted": {}}`（不再设 goal_achieved=true 防止循环）
  - 含触发关键字（如 "成功" / "预约"）→ goal_achieved=true + goal_type="appointment"（驱动 WRAPPING_UP 入口测试）
  - 裁判 prompt（含「请审查」）→ 默认 `{"passed": true, "reason": "ok"}`；含 "**reject**" 关键字 → `{"passed": false, "reason": "..."}`（驱动全部裁判否决兜底测试）
  - 润色 prompt（含「请润色」）→ 取 candidate[0] 的 reply 拼前缀「好的，」（确定性改写）
- **理由**：让 pytest 构造确定性测试；阶段 5 真 LLM 接入时只换 Provider，业务代码不动
- **替代**：mock 完全不变 → 测试只能跑一种路径；hardcode 测试 monkeypatch → 散落难维护

### 21. 意图分类器与独立判定 LLM 走 mock + provider switch

- **选择**：transfer_manager 的 intent / llm 触发都通过 `LLMProvider` 接口调用：意图分类调一次 LLM `chat(json_mode=True)` 返回 `{"intent": "transfer", "probability": 0.9}`；独立判定 LLM 调一次返回 `{"transfer": true}`；mock 实现按 prompt 关键字决定 probability / transfer 值
- **理由**：复用 LLMProvider，避免再加一类 Provider ABC；阶段 5 接真 LLM 时所有触发一并升级
- **替代**：独立 IntentProvider ABC → 又多一个 ABC 维护成本；hardcode mock → 阶段 5 切换难

### 22. pipeline_trace 字段完整 + 用 isales-common 模型直写

- **选择**：每轮 PROCESSING 完成后构造 `PipelineTrace` ORM 实例，包含 `call_record_id, turn_id, ts_start, ts_end, user_input, role_candidates(JSONB list), judge_results(JSONB list), polish_input(JSONB), polish_output(text), polish_duration_ms, polish_role_config_id, polish_prompt_version_id, final_selected_candidate_index, error(text|null)`，与 call_record 一起在 END 时事务批量 commit
- **理由**：transcript spec § pipeline_trace 字段约束；批量写避免每轮一次 fsync
- **替代**：每轮立即 commit → DB 写放大 + transcript 一致性难保证

### 23. transcript 事件统一通过 `session.append_event(event_type, **fields)` 写

- **选择**：CallSession 提供 `append_event(type, **fields)`：自动填 `ts = (now - call_started_at) * 1000`、按 transcript spec 事件类型枚举严格校验 type；同时按事件类型决定是否进 dialog_history（`greeting / user_speech / ai_reply` 进，其他不进）
- **理由**：transcript spec § 通用事件结构、§ dialog_history 与 full_transcript 双集合、§ 系统话术不入 dialog_history
- **替代**：散落在各模块自己 append → 容易漏 type / 漏 ts / 错把 silence 进 dialog_history

### 24. 调度依赖（DialRequest）与 prompt_versions snapshot

- **选择**：DialRequest 已含 scheduler 派发时打包的 `prompt_versions_snapshot`（按 retry-followup spec § scheduler 调度数据流）；CallSession 直接复用，写入 `call_record.prompt_versions`；engine **MUST NOT** 启动后再查 DB 的 prompt_version（避免与 scheduler 时刻不一致）
- **理由**：prompt 版本需在派发时刻冻结；engine 重新查会引入飘移
- **替代**：engine 自查 prompt_version → 与 scheduler snapshot 不一致 → 调试时复现失败

### 25. 错误边界：DB / Redis / Provider 短暂不可用

- **选择**：
  - Redis 短暂不可用：`event_publisher` / `event_consumer` 内部带退避重连；通话主路径只在 LPUSH `engine:worker:call-ended` / DECR 并发计数器时受影响 → 重试 3 次失败 → ERROR 日志，session 仍清理（接受 Redis 计数器一次性偏差，等系统重启对账）
  - DB 短暂不可用：CallSession 缓存 transcript / pipeline_trace 在内存；END 时写 DB 失败 → 重试 3 次（指数退避）；最终失败 → ERROR 日志，session 仍清理（接受丢一次 call_record，靠 audit log）
  - Provider 短暂不可用：单 LLM 超时 / 异常 → 该候选淘汰；全部失败 → 默认回复兜底
- **理由**：service-communication spec § 通信故障的容错；通话主路径不能被基础设施抖动卡死
- **替代**：失败抛出导致 session 卡住 → 用户挂线后 engine 还以为在通话；不重试直接放弃 → 抖动期间数据丢失偏多

### 26. 不实现"对话超长摘要"

- **选择**：dialog_history 全量喂角色 LLM；超 LLM context 由 Provider 抛 `ProviderInvalidRequest`，orchestrator 走默认回复兜底
- **理由**：role-prompt spec § 对话过长不做截断
- **替代**：自动调用摘要 LLM → 引入额外延迟与 token 成本，违反 spec

### 27. 单实例并发上限：engine 进程内 8 路 = service-communication 全局 8 路

- **选择**：engine 进程内不再做本地并发计数；完全依赖 Redis `isales:concurrency:active`（scheduler 已 INCR、engine 进 END 时 DECR）；engine 不主动拒收 DialRequest（如果 scheduler 派多了，engine 也尽力跑——但因为 scheduler 已经在派发前 INCR，理论上不会超）
- **理由**：service-communication spec § 全局并发控制；本地计数器 MUST NOT 替代
- **替代**：engine 本地再加一道阀 → 与 scheduler 阀重复且可能不一致

## Risks / Trade-offs

| 风险 | 缓解 |
|---|---|
| 三层管线总延迟 = max(N 路角色) + max(N×M 路裁判) + 1 路润色 ≈ 12s 最坏，超过用户耐心 | 单 LLM 8s 超时；LLM Provider 选低延迟产品（阶段 5）；fillers 覆盖；real time 验收时若发现尾延迟超 10s 调小超时阈值 |
| Mock Provider 偏离真实 LLM 行为 | 阶段 5 接真 Provider 时再做端到端 5 轮对话回归；mock 仅覆盖结构性 / 状态机分支 |
| MockTelephonyClient 与真 modem-controller IPC 行为差距大 | 抽象 `TelephonyClient` ABC 严格按 dial / hangup / connected / remote_hangup / audio 端点；阶段 6 新加的 `RealTelephonyClient` 提交时跑同一套 `tests/test_telephony_client_contract.py` |
| 状态机非法转移在生产环境频发（如 LLM 异常时模块乱发事件）| `IllegalTransition` 抛后 transcript 写 state_error；外层强制进 END(reason=`engine_internal_error`)；告警在第一次出现就响 |
| pipeline_trace 表膨胀（每通通话 × 每轮一条 + JSONB 候选 / 裁判 / 润色） | 单条 ~4-10 KB；v1 每天数千通 × 每通 ≤30 轮 ≈ 1 GB/天；spec 没强制 retention；v2 加分区 + TTL；本 change 不实现清理 |
| EngineEvent publish 在 Redis 抖动期间挤压 | fire-and-forget 不阻塞主路径；publish 内部带 `asyncio.wait_for(timeout=2s)` 防止单次 publish 卡死；timeout 后 WARN 日志 |
| 优雅停机时长 (>30s) 卡住 systemd | session 主动 cancel 自己的 task；shutdown 整体超时 30s；超时后强制 SIGKILL（接受最坏丢一两条 call_record）|
| MockTelephony audio frame 节拍与真 modem-controller PCM 流速差异导致沉默 / 打断检测在阶段 6 重新调参 | filler / silence / interruption 的所有阈值都是 Campaign 级配置；阶段 6 联调时按真实节拍重新校准默认值（DESIGN 不锁死可调默认值，按 feedback memory）|
| Redis 计数器在 engine 异常崩溃时泄漏 | session_manager 在异常路径也 DECR；服务重启时清理 stale 计数（v2 候选：心跳 + 对账，本 change 不实现）|
| 多 filler_set 在 sort_order 相同时顺序不稳定 | sort_order 按主键 id 排稳定 tiebreaker（与 worker 4.5 同款）|
| WRAPPING_UP 期间用户提新问题反复触发简化管线 → 预算耗尽 | 双计数器（轮数 + 时长）任一耗尽就挂断；用户反悔仍走收尾不退主管线 |
| 转人工触发与 WRAPPING_UP 的优先级 | 收尾期间用户说「我要转人工」时 transfer 让 wrap_up 让位（spec § 收尾期间的特殊情况处理）|
| dialog_history 超长导致 prompt 超 token | role-prompt spec § 对话过长不做截断；token 用量记 pipeline_trace；超阈值告警；阶段 5 真 LLM 上线后再观察 |

## Migration Plan

不适用——新仓库 + 首次部署，无运行时迁移。

部署：
1. 配 `ISALES_DATABASE_URL` / `ISALES_REDIS_URL` / `ISALES_ENGINE_LLM_PROVIDER=mock` / `ISALES_ENGINE_ASR_PROVIDER=mock` / `ISALES_ENGINE_TTS_PROVIDER=mock` / `ISALES_ENGINE_TELEPHONY_MODE=mock` / `ISALES_ENGINE_PIPELINE_DEFAULT_TIMEOUT_MS=8000` / `ISALES_ENGINE_MAX_NO_PROGRESS_SECONDS=60` / `TZ=Asia/Shanghai`
2. systemd 拉 `isales-engine.service`
3. 验收：用 `python -m scripts.fake_dial --campaign-id <id> --mock-asr-script <yaml>` 注入 → 观察日志 / `call_record / pipeline_trace / engine:worker:call-ended` 队列写入
4. 阶段 5 接真 Provider 时按 env 切换 `ISALES_ENGINE_LLM_PROVIDER=...` / `=...`；阶段 6 切 `ISALES_ENGINE_TELEPHONY_MODE=unix-socket`

## Open Questions

- 三层管线 Layer 1 → Layer 2 是否要支持"早送"（首个候选返回即开 Layer 2）：当前决策"等满"，阶段 5 看真 LLM 尾延迟再决定
- 三层管线总超时 vs 各层独立超时：当前各层独立（每个 LLM 8s）；阶段 5 看是否需要全局上限（如 15s 必须挂出 reply）
- ASR partial 推送频率（mock 默认每 200ms 一次）是否能覆盖打断 / 沉默场景：单测全覆盖；阶段 5 接真 ASR（豆包 / 火山）时回归
- pipeline_trace 是否需要在中间状态先 flush（避免 engine 崩溃时丢失整通 trace）：当前 END 时一次性写；v2 候选改为每轮 PROCESSING 完成立刻 flush
- WRAPPING_UP 期间检测到用户连续 5 次"反悔"是否要主动挂断：当前不实现，按 spec 走双计数器自然结束；阶段 4 验收发现问题再加
- 优雅停机时若有 session 在 PROCESSING 中是否要等管线完成：当前 cancel + 写 hangup；阶段 4 验收若发现 transcript 缺最后一轮 ai_reply 则改为"等当前 PROCESSING 完成再退"
- recording_url 由 modem-controller 阶段 6 写：本 change call_record 落 NULL；阶段 6 上线后由 worker 上传 OSS 后回写——这个写入路径的 spec 需在阶段 6 change 中明确（worker 还是 modem-controller 直接写）
- voice_model 选择：本 change 直接用 campaign.voice_model_id（阶段 2B 已 CRUD）；TTS Provider 接 voice_id 时只 mock 不真合成
- 跟进通话的 `last_call_summary` 来自 DialRequest（scheduler 已注入）；engine 不查 DB——已确认 isales-common v0.1.2 DialRequest 已含此字段
