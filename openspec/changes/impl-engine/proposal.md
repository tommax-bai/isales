## Why

阶段 4 的 isales-engine 是整个系统的核心：消费 scheduler 的 `engine:dial` 队列，驱动单通通话的状态机（`INIT → GREETING → LISTENING/SPEAKING/PROCESSING → ... → END`），编排 AI 三层并行管线（N 路角色 PK → N×M 路裁判 → 1 路润色），落 transcript / pipeline_trace、向 worker 派 `CallEnded`、向 api 推 `EngineEvent`。本 change 按 IMPLEMENTATION_PLAN.md 阶段 4 与 `call-state-machine` / `ai-pipeline` / `role-prompt` / `goal-achievement` / `filler` / `interruption-detection` / `silence-activation` / `human-handoff` / `transcript` / `service-communication` / `message-contract` / `provider-abc` 等 spec 实施 engine 骨架——**用 isales-common 已发的 Mock Provider 接通端到端**，不接真实 LLM/ASR/TTS（阶段 5），也不接 modem-controller IPC 与真实硬件（阶段 6）。

由于 modem-controller 还未实现真实硬件接入（阶段 6），本 change 提供一个进程内 `MockTelephony`：模拟 connected / 远端挂机 / PCM 上下行帧（驱动 mock ASR），让阶段 4 即可独立验收"5 轮对话 + 打断 + 沉默激活 + 转人工 + 兜底 + 润色降级 + 10 路并发计数器"完整链路。同时提供 `scripts/fake_dial.py` 注入合法 `DialRequest` 到 `engine:dial`，无需 scheduler 也能验收。

## What Changes

- **isales-engine 仓库新建**（独立 git repo，pip install isales-common >= 0.1.2）
  - 仓库骨架：`pyproject.toml`、entry point（`isales-engine`）、CI、Redis client wrapper、DB session、settings

- **DialRequest 队列消费**（service-communication spec § scheduler→engine 通道）
  - 后台 task `BLPOP engine:dial`（timeout=1s）
  - 用 isales-common `DialRequest` 反序列化（schema_version=1 支持，其他 → `LPUSH engine:dlq` + WARN 日志，按 message-contract spec）
  - 单条消息 → 创建 `CallSession`，注册到 `SessionManager`，启动状态机
  - **Redis 并发对账**：scheduler 派发前已 `INCR isales:concurrency:active`；engine 进 `END` 时 SHALL `DECR`（service-communication spec § 防计数器泄漏）；session manager 在异常清理时也 DECR，防泄漏

- **状态机 + CallSession**（call-state-machine spec 全实施）
  - `state_machine.py`：枚举 11 个状态（`INIT / GREETING / LISTENING / SPEAKING / INTERRUPTED / FILLER / PROCESSING / WRAPPING_UP / ACTIVATING / TRANSFERRING / END`）+ 统一事件驱动 API（`session.transition_to(NEW_STATE, reason=...)` + `on_event(event)`）；非法转移 → 抛 `IllegalTransition`，写 transcript `state_error` 事件兜底
  - `call_session.py`：单通通话所有上下文（dialog_history / full_transcript / 已用垫词记录 / 沉默激活计数 / 连续打断计数 / WRAPPING_UP 双计数器 / pipeline_trace 累积 / prompt_versions snapshot / 当前 turn_id / 启动时间）+ 全部 timer（沉默 / max_no_progress）
  - `session_manager.py`：进程内全局 `dict[call_id, CallSession]`；启动 / 注销 hook（注销时 DECR Redis 并发）；优雅停机时 cancel 所有 session 的 task 并补一条 `hangup{reason='engine_shutdown'}` 事件落库
  - **状态转换写 transcript**：每次 `transition_to` 都按 transcript spec 落对应类型事件（含 `ts` 相对通话开始的毫秒）

- **三层并行管线 orchestrator**（ai-pipeline spec + role-prompt spec + goal-achievement spec 全实施）
  - `pipeline/orchestrator.py`：`run_pipeline(session, user_input) -> PipelineOutcome{reply, goal_achieved, goal_type, extracted, selected_candidate_index}`
    1. 同时启动 N 路 `role_llm.call`（asyncio.gather + return_exceptions）+ FILLER（详见 filler 模块）
    2. 收齐角色候选；JSON 解析失败的候选直接淘汰
    3. 任一候选解析成功即送 Layer 2（裁判并行）；裁判任一否决即淘汰；全部失败 → 走 `default_replies` 兜底（写 transcript `default_reply_used`）
    4. 通过裁判的候选 → Layer 3 润色：润色超时 / 异常 / JSON 错 → 取通过裁判的第一个候选作为兜底
    5. 标记字段（goal_achieved/goal_type/extracted）从被选中候选直接继承（不投票）
    6. 全部细节写入 `pipeline_trace`（按 transcript spec § pipeline_trace 字段约束）
  - `pipeline/role_llm.py`：单角色调用（用 `LLMProvider.chat(json_mode=True)` + role-prompt spec 三段式 user message + WRAPPING_UP 末尾追加段落 + 跟进段落）；JSON 解析两步保护（json.loads → 正则提取 → 失败标记）
  - `pipeline/judge_llm.py`：单裁判调用（输入仅 reply 字段）→ `{passed, reason}`
  - `pipeline/polish_llm.py`：润色调用（输入是通过裁判的候选集合）→ 选优 + 改写 reply
  - `pipeline/json_parser.py`：单角色 LLM 输出 → `{reply, goal_achieved, goal_type, extracted}` 解析；两步兜底（json.loads / 正则）；全部失败时该候选标记 `parse_failed=True`
  - `pipeline/wrap_up_pipeline.py`：WRAPPING_UP 期间走简化管线（取 sort_order 最小的角色 + 润色，不 PK 不裁判）
  - `pipeline/greeting.py`：开场白生成（固定模板 / LLM 单角色生成；不调裁判 / 润色，按 ai-pipeline spec § 开场白不走管线）；开场白文本写入 dialog_history
  - **prompt_versions snapshot**：CallSession 初始化时一次性查 `role_config.current_prompt_version_id` 写入 `call_record.prompt_versions`（按 role-prompt spec § 通话开始时写入快照）

- **实时行为模块**
  - `realtime/filler_manager.py`（filler spec 全实施）
    - 触发场景白名单：仅常规对话 PROCESSING 触发；GREETING 后第 1 轮 / WRAPPING_UP / TRANSFERRING / ACTIVATING / 收尾告别 MUST NOT 播
    - 与管线**同时**启动；管线先返回 → 等垫词播完再接 reply
    - 多 filler_set 按 sort_order 升序循环 + 集合内随机不重复（call_session 内存态记录已用 phrase id）
    - 预生成失败 / 下载失败 → 跳过（无声延迟，不引入万能兜底）
    - 写 transcript `filler` 事件（含 phrase_id / duration_ms）
  - `realtime/interruption_detector.py`（interruption-detection spec 全实施）
    - 双条件：白名单完全等于 OR 时长 < `interruption_min_duration_ms` → 不视为打断
    - 满足打断 → 立即 stop TTS、状态 SPEAKING → INTERRUPTED → PROCESSING（用 ASR 终态文本）；不可撤销
    - 连续打断保护：counter ≥ `max_continuous_interruptions` → 按 `continuous_interruption_strategy` 走 `short_reply`（prompt 临时追加"请用一句话回应"）或 `listen_only`（说"您请说"进纯听）
    - 完整轮次（无打断 SPEAKING 完成）→ counter 清零
    - FILLER / WRAPPING_UP 状态判定一致；FILLER 命中打断 → 停垫词 + 丢弃当前 PROCESSING + 新轮 PROCESSING
  - `realtime/silence_detector.py`（silence-activation spec 全实施）
    - 计时起点：`max(用户最后一次 speech_end, AI 上一轮 TTS 播完)`；超 `silence_threshold_ms` 触发激活
    - 已激活次数 < `max_silence_activations` → 取 `silence_phrases[i]` 进 ACTIVATING；不足时复用最后一条；超量截前 N 条
    - 已达上限 → 播 `silence_hangup_phrase` → END(reason=`silence_max_reached`)
    - 激活话术写 full_transcript（`silence_activation` 事件），MUST NOT 进 dialog_history
    - 转人工触发优先级 > 沉默激活
  - `realtime/no_progress_timer.py`（call-state-machine spec § 长时间无进展挂断）
    - 用户一直说但全被判定"非打断/无效内容"超 `max_no_progress_seconds` → END(reason=`no_progress_timeout`)

- **转人工 manager**（human-handoff spec 全实施）
  - `transfer/manager.py`：4 种触发独立可配 + OR 关系
    - keyword：ASR 终态结果包含 `transfer_keywords` 任一
    - intent：意图分类器输出概率 > `transfer_intent_threshold`（v1 用 mock 分类器，stage 5 接真）
    - rounds：对话轮次 > `transfer_round_threshold` 且 goal_achieved=false
    - llm：独立判定 LLM 输出 `{"transfer": true}`
  - 命中 → 状态 → TRANSFERRING；从 `transfer_phrases` 随机抽 1 → TTS 播完 → 主动挂断 → call_record 写 `transfer_status='marked_for_handoff'` + `transfer_reason=<触发类型>` → END(reason=`marked_for_handoff`)
  - TRANSFERRING 期间 ASR 继续，仅补录 transcript；MUST NOT 调 AI 管线；MUST NOT 二级分支（无转接成功/失败）
  - **handoff_task 由 worker 阶段 3B 创建**——engine 仅写 `transfer_status` 与 `transfer_reason`

- **WRAPPING_UP manager**（goal-achievement spec § 收尾双计数器）
  - `wrapup/manager.py`：润色返回 `goal_achieved=true` → 当前轮 SPEAKING 正常播完 → 进 WRAPPING_UP；写 `call_record.wrap_up_started_at = now`
  - 双计数器：轮数 `wrap_up_max_rounds`（默认 2）+ 时长 `wrap_up_max_seconds`（默认 15）；任一耗尽 → 播 `wrap_up_closing_phrases` 随机一条 → END(reason=`wrap_up_completed`)
  - WRAPPING_UP 期间走 `wrap_up_pipeline.py`（简化管线）；用户提新问题 / 反悔 / 主动挂机 / 转人工触发 — 按 spec § 收尾期间的特殊情况处理

- **Mock providers 接入**（provider-abc spec § Provider ABC 契约可被 mock 测试）
  - 直接复用 `isales_common.providers.testing` 的 `MockLLMProvider / MockASRProvider / MockTTSProvider`（v0.1.2 已含）
  - `engine/providers/factory.py`：按 settings `ISALES_ENGINE_LLM_PROVIDER=mock`（默认）/ `openai` / `volcengine` / ... 选择实现；非 mock 全部 NotImplementedError 留给阶段 5
  - mock LLM 行为：根据 prompt 中是否含「请用一句话回应」/ 收尾段落 / 跟进段落，返回不同确定性 JSON（驱动 5 轮对话 / 兜底 / 润色降级 / goal_achieved 等场景测试）
  - mock ASR：feed 文本输入，按帧节拍推 partial / final（驱动 interruption_detector + silence_detector 单测）
  - mock TTS：返回固定 PCM bytes 流 + 标记播放完成（驱动 SPEAKING / FILLER 状态转移）

- **MockTelephony（进程内）**
  - `realtime/telephony_client.py`：抽象 `TelephonyClient` ABC（`dial` / `hangup` / `audio_in` / `audio_out` / `on_event`），阶段 4 用 `MockTelephonyClient` 实现：
    - `dial(phone)` → 异步等 `mock_connect_delay_ms` → 触发 `connected` 事件
    - `hangup()` → 触发 `local_hangup` 事件并停 audio
    - `audio_in/out`：用 asyncio Queue + bytes 帧；mock 模式按 mock TTS 流出帧、按测试注入流入帧
    - `simulate_remote_hangup()` → 触发 `remote_hangup` 事件
  - 阶段 6 由 `RealTelephonyClient` 替换（连真 modem-controller IPC）；本 change 不实现真客户端

- **EngineEvent 推送**（service-communication spec § engine→api Pub/Sub）
  - `event_publisher.py`：按 message-contract spec `EngineEvent` discriminated union 构造事件并 `PUBLISH engine:events:campaign:{campaign_id}`
  - 关键事件：`call_started / state_changed / asr_partial / asr_final / ai_reply / hangup / pipeline_completed`（具体子类型由 isales-common v0.1.2 EngineEvent union 定义）
  - 异步 fire-and-forget；publish 失败 → WARN 日志，不影响通话

- **EngineControl 消费**（service-communication spec § api→engine Pub/Sub）
  - `event_consumer.py`：`SUBSCRIBE engine:control:campaign:*`，反序列化 `EngineControl` discriminated union
  - 子类型：`ManualHangup{call_id}` → 找 session、状态 → END(reason=`manual_hangup`)；`ForceTransfer{call_id}` → 触发 transfer_manager.start("manual")
  - 不存在的 call_id → WARN 日志静默丢弃

- **CallEnded 派发**（service-communication spec § engine→worker 队列）
  - 状态进 END 时：写 `call_record.transcript / hangup_cause / ended_at / transfer_status / wrap_up_started_at`、`pipeline_trace` 各轮记录、`call_record.recording_url=NULL`（v1 录音由 modem-controller 阶段 6 接，本 change 不写）
  - 用 isales-common `CallEnded` 类构造（schema_version=1）→ `LPUSH engine:worker:call-ended`
  - **DECR 并发计数器**：`DECR isales:concurrency:active`（service-communication spec § 防计数器泄漏）；session manager 在异常崩溃时也走同一路径

- **mock dial 注入脚本**
  - `scripts/fake_dial.py`：argparse `--db-url` `--redis-url` `--campaign-id` `--lead-id?` `--phone-number?` `--voice-model-id?` `--mock-asr-script <path>` `--simulate-hangup-after-seconds?`
  - 步骤：可选建 lead（如未指定）→ 装载 `--mock-asr-script`（YAML：每秒 / 每事件触发的 ASR 文本）→ 构造 DialRequest（含 prompt_versions 快照查询自 DB）→ INCR `isales:concurrency:active` → `LPUSH engine:dial`
  - 用于阶段 4 独立验收：操作员跑此脚本，观察 `call_record / pipeline_trace / lead.status='calling'` 的写入与状态机转换日志
  - 不进 production runtime；MUST NOT 在 `[project.scripts]` 暴露

- **测试**
  - pytest + pytest-asyncio + 真 PG + 真 Redis + Mock Providers
  - 状态机：所有合法转移路径（GREETING / 第 1 轮 PROCESSING / SPEAKING / INTERRUPTED / FILLER / ACTIVATING / TRANSFERRING / WRAPPING_UP / END）
  - 状态机：非法转移 → IllegalTransition + 写 state_error
  - DialRequest 消费：合法消息走完整链路、schema_version=99 → DLQ；call_record 创建包含 prompt_versions snapshot
  - 三层管线：N=2 角色 + M=1 裁判：全部通过、单角色 JSON 失败、全部裁判否决、润色超时降级、润色 JSON 错降级、所有路径写 pipeline_trace 完整
  - 标记字段不投票：候选 1 goal=true / 候选 2 goal=false → 润色选 1 → final goal=true；选 2 → final goal=false
  - 开场白：固定模板 / LLM 生成两路径；都写 dialog_history；都不调裁判润色
  - filler：常规 PROCESSING 触发；GREETING 后第 1 轮不触发；WRAPPING_UP 不触发；多 set 轮询 + 集内不重复；管线先返回等垫词；预生成失败跳过
  - 打断：白名单不触发、时长<阈值不触发、命中触发立即停 TTS；连续打断 short_reply / listen_only 两策略；FILLER 期间打断停垫词
  - 沉默：触发激活、计时起点正确（max(speech_end, tts_end)）、激活上限挂断、激活话术不入 dialog_history、转人工优先于沉默
  - 转人工：4 种触发独立路径 + OR 命中；衔接话术随机；TRANSFERRING 不调管线；call_record 字段写入；END(reason=marked_for_handoff)
  - 收尾：goal_achieved=true 进 WRAPPING_UP；轮数耗尽 / 时长耗尽各路径；用户反悔走简化管线不退主管线；用户提新问题继续简化管线；TRANSFERRING 触发让位
  - EngineEvent：状态变更触发 publish；asr_partial/final、ai_reply、hangup 事件序列；publish 失败不影响通话
  - EngineControl：ManualHangup 找到 session 进 END(manual_hangup)；不存在的 call_id 静默
  - CallEnded：进 END 时正确 LPUSH；transcript / pipeline_trace 各表写入；DECR 并发
  - 并发：MockTelephony 起 10 路并发 mock 通话，所有 session 独立、并发计数器准确进退
  - 端到端：`fake_dial.py` 注入 → 5 轮 mock 对话 → goal_achieved=true → WRAPPING_UP → END → DB / `engine:worker:call-ended` 校验
  - 优雅停机：systemctl stop（SIGTERM）→ cancel 所有 session task → 写 hangup{reason=engine_shutdown} → DECR 并发 → 进程退出

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `call-state-machine`: 修改 Requirement "状态集合"——把"非法状态转移的兜底"从隐式约定提升为硬契约：状态机在收到不属于当前状态合法转移集合的事件时 MUST 抛 `IllegalTransition` 异常并向 transcript 追加 `{type: "state_error", attempted: <event>, from_state: <current>}` 事件；session 如能恢复（如忽略事件）SHALL 继续；不能恢复（如 PROCESSING 中 modem-controller 心跳丢失）MUST 强制进 END(reason=`engine_internal_error`)。这是 engine 内部状态机与运行时的硬契约，被前端 / 运维通过 transcript 调试时依赖。

- `ai-pipeline`: 修改 Requirement "三层并行管线编排"——把 orchestrator 与 pipeline_trace 表的写入时机从隐式约定提升为硬契约：每轮 PROCESSING 完成（无论走完整管线 / 默认回复兜底 / 润色降级 / 简化管线）MUST 落一条 `pipeline_trace` 记录，含全部候选 / 裁判 / 润色字段（按 transcript spec § pipeline_trace 字段约束）；若 PROCESSING 中途异常（如 LLM Provider 全部超时）MUST 仍写一条 `pipeline_trace`，标注 `error` 字段；MUST NOT 因写 pipeline_trace 失败而影响通话主路径（用 try/except 包裹）。

其余对 `architecture` / `goal-achievement` / `role-prompt` / `filler` / `interruption-detection` / `silence-activation` / `human-handoff` / `transcript` / `service-communication` / `message-contract` / `provider-abc` 等 spec 是 engine 侧的**首次实施**，不修改其 requirement。

## Impact

- **新仓库**：`isales-engine`（独立 git repo）
- **isales-common 依赖**：v0.1.2（含全部消息类 / Provider ABC / Mock Provider / 模型），**不需要 bump**
- **依赖链**：本 change 完成后，scheduler → engine → worker 链路在阶段 4 即真闭环（除真实 LLM/ASR/TTS 与真实硬件外）；scheduler 可从 mock consumer 切到真 engine；worker 可从 mock CallEnded 切到真 engine 派发的 CallEnded
- **可独立实施**：scheduler / worker 已上线（其侧 mock 工具仍保留），engine 上线后两侧 mock 不立刻删除（保留作开发与回归）；alembic 不动
- **不影响**：isales-web / isales-common 不需要任何改动；isales-api / isales-telephony 已部署，本 change 仅消费它们留下的数据并写它们订阅的 channel
- **新环境变量**：
  - `ISALES_ENGINE_LLM_PROVIDER`（mock 默认；openai / volcengine / alibaba / ... 留给阶段 5）
  - `ISALES_ENGINE_ASR_PROVIDER`（同上）
  - `ISALES_ENGINE_TTS_PROVIDER`（同上）
  - `ISALES_ENGINE_TELEPHONY_MODE`（mock 默认 / unix-socket 留给阶段 6）
  - `ISALES_ENGINE_MAX_NO_PROGRESS_SECONDS`（默认 60）
  - `ISALES_ENGINE_PIPELINE_DEFAULT_TIMEOUT_MS`（角色 / 裁判 / 润色 LLM 各自的超时上限，默认 8000）
  - `TZ=Asia/Shanghai`（与 scheduler / worker / api 共享）
- **Redis 通道**：`engine:dial`（消费）/ `engine:worker:call-ended`（生产）/ `engine:events:campaign:{id}`（生产 PUBLISH）/ `engine:control:campaign:*`（消费 SUBSCRIBE）/ `engine:dlq`（生产，schema 不兼容 dead letter）/ `isales:concurrency:active`（DECR）
- **超出本 change 范围**：真实 LLM/ASR/TTS Provider 实现（阶段 5 的 `impl-engine-providers`）；真实 modem-controller IPC 与硬件接入（阶段 6 的 `impl-engine-hardware`）；录音上传（modem-controller 阶段 6 写 `recording_url`）；前端实时监控（阶段 7 isales-web 实施）
