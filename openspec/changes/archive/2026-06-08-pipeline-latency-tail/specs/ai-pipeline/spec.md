## ADDED Requirements

### Requirement: main streaming 播放流水线（producer/consumer + 预合成）

main LLM 流式回复的"生成 → TTS 合成 → 播放"三级 MUST 并发流水化，MUST NOT 串行到"播完一句才生成/合成下一句"。engine SHALL 用 producer task 持续消费 `chat_stream → split_sentences`、并对每句**立即**发起 TTS 合成，把就绪句柄塞入一个有界队列；consumer task 从队列取出并播放。播第 N 句时第 N+1 句的 TTS SHALL 已在合成中。

队列 MUST 有界（默认上限 2 句），以限制 main LLM 领先播放的程度、限制 barge-in 时已合成音频的沉没成本。

#### Scenario: 生成不被播放挂起

- **WHEN** consumer 正在播放第 N 句音频
- **THEN** producer SHALL 继续消费 main LLM `chat_stream` 的后续 token 并切句、发起第 N+1 句 TTS 合成；main LLM 流 MUST NOT 因当前句播放而被挂起

#### Scenario: 句间无静音空档

- **WHEN** 第 N 句音频播放结束、队列里第 N+1 句已就绪
- **THEN** consumer SHALL 立即开始播放第 N+1 句；句间 MUST NOT 出现等待 TTS 合成首字节的静音空档

#### Scenario: first_audio_ms 记录点不变

- **WHEN** consumer 播放队列里第一句的首 PCM chunk
- **THEN** engine SHALL 记录 `pipeline_trace.first_audio_ms`（自 PROCESSING 入口起算），语义与 pipeline-stream-and-referee 一致

#### Scenario: barge-in 兼容三态

- **WHEN** partial_monitor 在播放期间判定打断（cancel `current_speaking_task`）
- **THEN** engine MUST cancel consumer 当前播放 + cancel producer task + 关闭队列中未播句柄的 TTS iterator；该轮 `interrupted=True`；下一轮回 LISTENING；无论打断点落在"播放中 / 合成中 / 队列等待中"行为一致

### Requirement: transfer LLM 检测不阻塞 PROCESSING 入口

带 LLM 调用的转人工检测 MUST NOT 在 PROCESSING 入口之前同步执行。便宜的 keyword / round 检测 MAY 保留 inline（零 LLM、确定性）；intent / llm（含 LLM 调用）的检测 SHALL 优先复用 referee 的 `transfer` decision；过渡期对显式配置 `transfer_llm_enabled` 的 campaign，该 LLM 检测 SHALL 与 main streaming 并行 spawn（同 referee 模式），其结果在 SPEAKING 结束前 await，MUST NOT 卡在 PROCESSING 入口前。

#### Scenario: transfer 复用 referee 决策

- **WHEN** referee 返回 `decision="transfer"`
- **THEN** engine SHALL 据此转 TRANSFERRING，MUST NOT 为此额外串行调一次 transfer LLM

#### Scenario: 显式 transfer_llm campaign 走并行兜底

- **WHEN** campaign 显式 `transfer_llm_enabled=true`
- **THEN** 该 LLM 检测 SHALL 在 PROCESSING 入口与 main streaming 并行 spawn；MUST NOT 在 PROCESSING 之前同步 await
