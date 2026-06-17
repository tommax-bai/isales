## Why

开场白与第一句 AI 回复之间间隔明显偏长,之后的回复速度正常。多智能体诊断 + 对抗验证(run wsf0qkv7e)确认:开场白窗口期是一段几秒的空闲,但引擎此刻什么下游连接都没预热,导致 turn-1(第一句 AI 回复)独自承担所有一次性建连开销——固定开场白命中模板直接 return、不调 LLM(`pipeline/greeting.py:38-39`),所以 turn-1 的 `chat_stream` 是 main 槽这通电话第一次发请求、要付 TCP+TLS 握手(~100-200ms,`llm_openai_compatible.py:67-77` 注释自证);ASR WebSocket 又是开场白之后才懒连(`run_loop.py:205→209`,`_start_listen_pumps` 在 `_do_greeting` 之后),客户第一句话要等 WS 现连 + 配置帧握手才能 finalize 触发 PROCESSING(对抗验证 verdict=confirmed)。从第二轮起连接全热(httpx `keepalive_expiry=60s` 覆盖轮间间隔),所以"开场白→第一句慢,之后快"。provider 对象本身在 call 开始即 eager 构造(`main.py:209-226`),冷的是网络连接而非对象未初始化——把开场白这段空闲利用起来预热,即可把一次性握手开销从 turn-1 移走。

## What Changes

- 在开场白(GREETING 内部阶段)播放窗口内,**并行预热下游连接**,使 turn-1 拿到热连接:
  - **ASR WebSocket 提前建连**:把 ASR WS 的 connect + 配置帧握手提前到开场白播放期间并行完成。**硬约束**:开场白期间 MUST NOT 把入向音频喂进 ASR finalize(保持开场白不可打断、不把开场白回声/客户抢话喂进去);开场白结束后 drain 掉缓冲帧再开始正常 ASR 路由。
  - **main LLM 槽连接池预热**:在开场白窗口对 main 槽 client 发一次轻量预热请求,让 turn-1 的 `chat_stream` 复用热 keep-alive 连接池。固定模板 / LLM 生成两种开场白模式都覆盖。
- 预热失败 **fail-soft**:预热纯属优化,任一预热失败 MUST 回落到原懒连路径、不阻塞通话(唯一一层兜底,注释写明移除条件)。
- 复用现有 `pipeline_trace` 字段(`main_first_token_ms` / `main_first_sentence_ms` / `first_audio_ms`)做验收,**不新增 schema 字段**(纯 engine change,无 alembic / isales-common 改动)。

**Out of scope**(按"多层兜底是 code smell"原则收敛,不堆低确定性预热):

- 裁判槽单独预热:默认 `provider=None` 时共享 main 的 default client,已被 main 预热自然覆盖;仅当显式配独立 provider/model 才冷,作为 main 预热副产品处理,不单独堆层。
- TTS 连接预热:confidence low,且 active change `engine-tts-bidi-streaming` 在途会重写 TTS 路径,不在此 change 动。
- 厂商前缀缓存:全包无 `cache_control`、无法从代码证实,开场白也喂不进 turn-1 前缀缓存,不碰。

## Capabilities

### New Capabilities
<!-- 无新增 capability;本 change 只修改 ai-pipeline 既有行为 -->

### Modified Capabilities
- `ai-pipeline`: 新增「开场白窗口期预热下游连接」要求(GREETING 阶段并行预热 ASR WS + main LLM 连接,带 fail-soft 与"不打断/不喂音频"约束);并澄清既有「开场白不走管线」——"不走 referee/extractor 管线 ≠ 不预热下游连接"。

## Impact

- **代码**:`isales-engine` only。`run_loop.py`(开场白与 listen-pump 启动时序、ASR 提前连 + 开场白期音频不喂入 + 结束 drain)、`pipeline/greeting.py` 或 `_do_greeting` 调用点(触发 main 槽预热)、`providers/asr_volcengine.py`(支持"先建连、暂不消费音频"的入口或在 run_loop 侧编排)、`providers/llm_openai_compatible.py` / `providers/llm_registry.py`(轻量预热入口,若需要)。
- **无** isales-common / alembic / isales-api / isales-web 改动(纯 engine,复用既有 trace 字段)。
- **Spec**:`openspec/specs/ai-pipeline/spec.md`(经本 change 的 delta)。需避开 active engine changes(`engine-sentence-splitter-soft-boundary` / `engine-tts-bidi-streaming` / `engine-ambient-background-mix` / `engine-gate-supervision-rename`)的撞段——delta 尽量集中在新增 Requirement + 仅 MODIFY「开场白不走管线」一条。
- **验收**:对比同一通电话 turn-1 vs turn-2 的 `main_first_token_ms` / `first_audio_ms` 应显著收窄;ASR 首 finalize 不再含 WS 建连握手。真机验收沿用 `pipeline-stream-realmachine-acceptance` 方式(可挂 deferred)。
