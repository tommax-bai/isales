## Context

诊断(run wsf0qkv7e,7 读者 + 3 路对抗验证)定位:开场白与第一句 AI 回复之间的偏长间隔,根因是**开场白窗口期什么下游连接都没预热**,turn-1 独自承担一次性建连开销:

- 固定开场白命中模板直接 return、不调 LLM(`pipeline/greeting.py:38-39`)→ turn-1 的 `chat_stream` 是 main 槽这通电话第一次发请求,付 TCP+TLS 握手(~100-200ms,`llm_openai_compatible.py:67-77` 注释自证)。
- ASR WebSocket 懒连且在开场白之后才启动(`run_loop.py:205→209`,`_start_listen_pumps` 在 `_do_greeting` 之后;`asr_volcengine.py:354-355` 的 `__aenter__` 才真正 connect)→ 客户第一句话要等 WS 现连 + 配置帧握手才能 finalize 触发 PROCESSING。**对抗验证 verdict=confirmed**,且该开销落在 `processing_start` 之前的静默窗口,pipeline_trace 测不到。

第二轮起连接全热(httpx `keepalive_expiry=60s` 覆盖轮间间隔),故"开场白慢、之后快"。provider 对象本身 call 开始即 eager 构造(`main.py:209-226`,且 per-call 而非 per-process);冷的是网络连接,不是对象未初始化。承重墙修法=把开场白播放那几秒空闲利用起来,并行预热 turn-1 所需连接。

## Goals / Non-Goals

**Goals:**

- 在开场白播放窗口并行完成 ASR WS 建连 + main 槽 LLM 连接池预热,使 turn-1 的 `main_first_token_ms` / `first_audio_ms` 较 turn-2 的差距显著收窄、ASR 首 finalize 不再含 WS 建连握手。
- 预热不改变任何对外可观测行为:开场白仍不可打断、不把开场白期音频喂进 ASR finalize、预热失败 fail-soft 回落原路径。
- 纯 engine 改动,复用现有 pipeline_trace 字段验收,零 isales-common / alembic / api / web 改动。

**Non-Goals:**

- 裁判槽单独预热(默认 `provider=None` 共享 main 的 default client,`llm_registry.py:58-59` 短路返回 default,已被 main 预热覆盖;仅显式独立 provider/model 才冷,不为此单独堆层)。
- TTS 连接预热(confidence low;且 active change `engine-tts-bidi-streaming` 在途会重写 TTS 路径)。
- 厂商前缀缓存优化(全包无 `cache_control`、无法代码证实,开场白消息结构与主线不同也喂不进 turn-1 前缀缓存)。
- 跨通话连接复用(连接池 per-call,本 change 不改这一架构)。

## Decisions

### D1:预热与开场白播放并行,不串行前置

预热作为开场白播放期间的并行任务 fire,而非在通话接通后同步阻塞预热。理由:开场白播放本就要占几秒墙钟,把握手藏进这段空闲是零额外延迟的"免费"窗口;若改成接通后同步预热,反而把握手延迟前移到开场白之前,得不偿失。

*备选*:接通即同步预热——否决,等价于把开销搬家而非消除。

### D2:ASR 提前建连,但音频路由延后到开场白结束

把"ASR WS 建连"与"消费入向音频"两件事解耦:开场白窗口期只做 connect + 配置帧握手,**不**把入向音频喂进 finalize。开场白结束时 drain 掉这段缓冲帧,再开始正常 ASR 路由。理由:既拿到提前握手的收益,又严守两条既有不变量——开场白不可打断(`run_loop.py:196-197` 注释:listen pump 在开场白后启动正是为此)、不把开场白回声 / 客户抢话计入首句。

实现编排放在 `run_loop.py`:把当前"_do_greeting 完成 → _start_listen_pumps"的串行时序,改为"建连任务提前 kick off(fire-and-forget)+ 音频消费 gate 到开场白结束"。倾向于在 run_loop 侧编排,而非给 `asr_volcengine.py` 加"连了但不消费"的新状态,降低对 provider ABC 的侵入。

*备选*:让 ASR provider 内部支持"先连后喂"——否决,污染 provider 接口;时序编排是 run_loop 的职责。

### D3:main 槽预热请求——仅固定模板模式发轻量 probe

- **固定模板开场白**:开场白完全不调 LLM → 必须发一次轻量预热请求(极短 prompt、`max_tokens=1` 量级)warm 连接池。
- **LLM 生成开场白**:`generate_greeting` 已用 `providers.llm_for(config.pipeline.main)` 调 `chat`(`run_loop.py:339`),该调用已 warm **同一个** main 槽 httpx client 的连接池 → **不再**发冗余 probe。

注意对抗验证的精确边界:`build_greeting_messages` ≠ `build_main_messages` 只影响"厂商前缀缓存"(非本 change 目标),**不**影响连接池——连接池属于 httpx client 实例,LLM 开场白与 turn-1 `chat_stream` 共用同一 client,故连接池天然复用。预热的目标明确是连接池,不是前缀缓存。

*备选*:两种模式都发 probe——否决,LLM 模式属冗余请求(多一次计费 + 多余 token)。

### D4:fail-soft 单层兜底,带移除条件注释

预热纯属优化:ASR 提前建连失败 / main probe 失败一律 log + 回落到原懒连路径,不抛、不阻塞。这是本 change 唯一一层兜底(遵循"多层兜底是 code smell"),注释 MUST 写明移除条件——预热路径在生产稳定后,回落分支可删。

### D5:复用现有 pipeline_trace 字段验收,不新增 schema

`main_first_token_ms` / `main_first_sentence_ms` / `first_audio_ms` 已存在(`run_loop.py:1689-1690` 映射)。验收只需对比同一通电话 turn-1 vs turn-2,无需新字段 → 零 common / alembic 改动,纯 engine change。注意这些字段 isales-api 的 `PipelineTraceRead` 未暴露,验收读 DB(沿用诊断给出的 SQL)。

## Risks / Trade-offs

- **ASR 提前建连后、开场白播放期间无音频流,vendor 可能因 idle 超时断连** → 开场白通常仅几秒,短于 V3 SAUC 常见 idle 窗口;若实测断连,缓解=建连后按 vendor 协议发保活 / 静音占位帧(但占位帧 MUST 标记为不参与 finalize,避免误触首句)。**先按"开场白够短不会触发 idle 断连"实现,真机实测验证**;若证伪再加保活,作为 D2 的实现细节而非新兜底层。
- **开场白期缓冲帧 drain 不干净 → 把开场白回声 / 早到的客户音频当首句** → 开场白结束明确 drain `inbound_q` + ASR 侧从 drain 点开始消费;复用诊断建议(workflow:"drain inbound_q at connect")。
- **main probe 产生无用 token 计费** → `max_tokens=1` 量级,可忽略;仅固定模板模式发一次/通。
- **与 active engine changes 撞段**(`engine-sentence-splitter-soft-boundary` / `engine-tts-bidi-streaming` / `engine-ambient-background-mix` / `engine-gate-supervision-rename`):spec delta 仅 ADDED 一条 + MODIFY「开场白不走管线」一条,避开它们触碰的 requirement;代码层 `run_loop.py` 的开场白时序段与上述 change 的改动点(句界 / TTS / 背景混音 / 命名)不重叠,同 session 处理即可。

## Migration Plan

1. engine 实装 + 单测(ASR 提前连不喂音频 + 开场白后 drain;固定模板发 probe / LLM 模式不发;预热失败 fail-soft)。
2. scp 部署 engine 到 ECS + restart(纯 engine,无 alembic / common 版本联动;沿用既有 scp 部署纪律)。
3. 真机验收:拨测对比 turn-1 vs turn-2 的 trace 字段(可挂 `pipeline-stream-realmachine-acceptance` deferred)。
4. **回滚**:纯 engine 单仓回滚——scp 旧 `run_loop.py` + restart 即可;无 DB 迁移、无跨仓版本联动,回滚零风险。

## Open Questions

- 开场白播放时长分布是否稳定短于 ASR vendor idle 断连阈值?(决定是否需要 D2 的保活占位帧)——真机实测确认。
- main probe 的最小有效形态(纯连接 warm 是否需要真发一个 chat,还是可用更轻的握手)?——实装时以"能 warm keep-alive 连接池"为准,优先最轻请求。
