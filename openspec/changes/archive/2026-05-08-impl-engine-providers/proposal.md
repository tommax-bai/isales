<!-- PARTIALLY-SUPERSEDED-by: pipeline-stream-and-referee. The role/judge/polish
JSON-mode prompt assembly + json_parser built here is replaced by main plain-text
streaming + referee JSON. The provider ABCs / credential plumbing / TTS-ASR
provider work from this change remains (and gains LLMProvider.chat_stream). -->

## Why

阶段 4 的 isales-engine 已经把状态机 / 三层管线 / 实时模块 / 调度链路全部跑通，但所有 LLM/ASR/TTS Provider 都是 mock。阶段 5 的目标是把"端到端 mock 通话"升级为"端到端真实通话"——接 1 套真实 Provider（ASR：火山豆包；TTS：火山引擎；LLM：火山豆包大模型 + OpenAI 备选），让 engine 在不依赖真实硬件（stage 6）的前提下，可以用真音频文件 / 真线下麦克风跑出真 LLM 对话。同时把 stage 4 docstring 中标注的"SPEAKING 期间实时打断"补上——真 ASR 接入后才有意义。

按 IMPLEMENTATION_PLAN.md 阶段 5 与 `provider-abc` spec § Scenario "v1 默认 ASR Provider"（火山豆包）+ § Requirement "ASR Provider 异步流式接口" / "TTS Provider 异步流式合成接口" / "LLM Provider chat 接口与 JSON Mode" 实施。

## What Changes

- **真实 LLM Provider 实现**（按 provider-abc spec 三套 ABC）
  - `providers/llm_volcengine.py`：火山豆包大模型（doubao-pro / doubao-lite），原生 JSON Mode
  - `providers/llm_openai.py`：OpenAI Chat Completions（gpt-4o-mini / gpt-4o），`response_format={"type": "json_object"}` 启用 JSON Mode
  - 通用：`ProviderError` 体系（`ProviderTimeout` / `ProviderRateLimited` / `ProviderInvalidRequest` / `ProviderServerError`）；429 → ProviderRateLimited；5xx → ProviderServerError；超时 → ProviderTimeout；非法请求 → ProviderInvalidRequest
  - 通用：tokens_in / tokens_out 从 API 响应解析填回 LLMResponse；finish_reason / latency_ms 同步

- **真实 ASR Provider 实现**
  - `providers/asr_volcengine.py`：火山引擎实时语音识别（豆包）WebSocket 流式 API
  - 流式中间结果：每 partial 推一次 `ASRResult(text=..., is_final=False, timestamp_ms=...)`，speech_end → `is_final=True`
  - 入参：8kHz 单声道 PCM 16-bit LE chunks（与 stage 6 modem-controller PCM 通道格式一致）
  - 鉴权：env `ISALES_VOLCENGINE_APP_KEY` / `ISALES_VOLCENGINE_APP_TOKEN`
  - 失败兜底：WebSocket 中断 → 重连（带退避）；3 次重连失败 → 抛 `ProviderServerError`，由 run_loop 走 no_progress → END

- **真实 TTS Provider 实现**
  - `providers/tts_volcengine.py`：火山引擎 TTS 流式合成 API（首包 < 500ms 目标，按 spec § Scenario "流式输出首包"）
  - 入参 `(text, voice_id)`：voice_id 直接透传；voice_model 表的 voice_id 列在 isales-common 已定义
  - 输出 PCM 8kHz 单声道 16-bit LE bytes（与 ASR 同采样率，方便 stage 6 双向流转）
  - 失败兜底：超时 / 5xx → 重试 1 次（避免 LLM 已生成 reply 但 TTS 失败让用户感知卡顿）；最终失败抛 `ProviderTimeout`，run_loop 跳过该 reply 的 audio_out（保留 ai_reply transcript 但用户听不到）

- **provider 工厂增量**
  - `providers/factory.py`：扩展 `build_llm("openai" | "volcengine" | "mock")`、`build_asr("volcengine" | "mock")`、`build_tts("volcengine" | "mock")`；invalid name 仍 NotImplementedError 留给后续扩展（阿里 / 智谱 / Anthropic 等 v2）
  - 默认值：LLM=volcengine、ASR=volcengine、TTS=volcengine（与 spec § "v1 默认 ASR Provider" 一致）；mock 仍可用作测试

- **Campaign 级 model 切换**
  - `role_config.model` 字段（v0.1.2 已有）作为路由 key：`"doubao-pro"` / `"doubao-lite"` / `"gpt-4o-mini"` / 等
  - LLM Provider 实现内部按 model 字段选 endpoint / payload 形态；调用方（orchestrator 已穿透 role.model 字段）无需改
  - mock provider 忽略 model 字段（保持 stage 4 行为）

- **流式 ASR 真接入 + SPEAKING 期间实时打断**
  - 在 `run_loop._main_turn_loop` 增加并行 partial monitor：SPEAKING 状态下从 `asr_partials_q` 监听中间结果，每条调 `interruption_detector.evaluate_partial`
  - 命中打断 → 立即 `await audio_out_cancel(call_id)`（cancel SPEAKING 任务）→ 状态 SPEAKING → INTERRUPTED → PROCESSING；SPEAKING task 提供 cancel-aware 实现
  - FILLER 状态下同样：partial 命中打断 → cancel filler audio_out → 进 PROCESSING
  - 连续打断 counter（CallSession.consecutive_interruption_count）：counter ≥ campaign.max_continuous_interruptions → 按 campaign.continuous_interruption_strategy 走 short_reply（PipelineConfig.short_reply_active=True）或 listen_only（不调 LLM，TTS 播 "您请说" 后回 LISTENING）
  - 完整轮次（无打断 SPEAKING 完成）counter 清零

- **TelephonyClient 流式 ABC 微调**
  - `audio_out` 现在支持 cancel：实现方在被 `asyncio.CancelledError` 触发时 MUST 立即停止剩余 chunks，避免缓冲区残留把 reply 末尾推给已经在新 PROCESSING 的用户。MockTelephonyClient 同步加 cancel 行为。
  - `audio_in` 已是 AsyncIterator，无需改

- **token 用量监控 + 告警**
  - 每条 LLMResponse 的 tokens_in/out 写入 pipeline_trace.role_candidates / judge_results / polish_input（字段已在 transcript spec 定义为 prompt_tokens / completion_tokens）
  - 单通通话 token 累计超 `ISALES_ENGINE_TOKEN_BUDGET_PER_CALL`（默认 50000）→ WARN 日志 + 通过 EventPublisher 推 `TokenBudgetExceeded` 事件（新增 EngineEvent 子类型，待 isales-common 升 0.1.3）；spec 留 hook 但本 change 仅日志告警

- **测试**
  - 单元测试：每个 provider 的 happy path / timeout / 429 → ProviderRateLimited / 5xx → ProviderServerError / JSON 解析失败 / 鉴权失败
  - 用 httpx.MockTransport / aioresponses / fake WebSocket server 隔离真供应商
  - 集成测试（可选）：`tests/test_real_providers.py` 跑真 API（用 env `ISALES_LIVE_PROVIDER_TESTS=1` 启用），CI 默认跳过
  - run_loop 实时打断测试：用 ScriptedMockASR 在 SPEAKING 期间 feed partial → 验证 SPEAKING task 被 cancel + 进 PROCESSING + 连续打断 counter；ScriptedMockASR 加新 API `feed_partial_during_speaking`
  - 兜底链路测试：所有 LLM 全部 ProviderTimeout → orchestrator 走 default_reply（已 stage 4 测试）；TTS Provider 失败 → audio 静音但 transcript 保留

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `provider-abc`: 修改 Requirement "统一错误模型"——把 `ProviderError` 体系的"具体异常类型与触发条件"从隐式约定提升为硬契约：HTTP 429 MUST 抛 `ProviderRateLimited`；HTTP 5xx / 网络错误 / 连接超时 MUST 抛 `ProviderServerError`；请求超时 MUST 抛 `ProviderTimeout`；HTTP 4xx 非 429 MUST 抛 `ProviderInvalidRequest`；JSON 解析失败 MUST 抛 `ProviderInvalidRequest`（响应体不符合契约）。orchestrator / 实时模块依赖这套异常分类做降级决策。

- `ai-pipeline`: 修改 Requirement "三层并行管线编排"——增加"打断保护策略"硬契约：连续打断超 `max_continuous_interruptions` 时 `PipelineConfig.short_reply_active=True` 触发 prompt 中追加"请用一句话回应"段落（已在 stage 4 prompt_builder 实现）；engine MUST 在 SPEAKING 完成而无打断时清零 `consecutive_interruption_count`。本 Requirement 把 "stage 4 留给 stage 5 follow-on 的实时打断"提升为已落地。

其余对 `interruption-detection` / `service-communication` / `transcript` 等 spec 是 engine 侧的**首次完整实施**（stage 4 stage 5 一并），不修改其 requirement。

## Impact

- **isales-engine 仓库改动**：新增 `providers/{volcengine,openai}/{llm,asr,tts}.py`、`providers/_errors.py`（如 isales-common 未提供）；run_loop 增 partial monitor 子任务 + audio_out cancel；factory 增分支
- **isales-common 依赖**：v0.1.2 仍可用；可选 bump v0.1.3 加入 `TokenBudgetExceeded` 事件（本 change 不强制，仅日志）
- **依赖链**：本 change 完成后 stage 6（hardware）只剩 modem-controller IPC + RealTelephonyClient；engine 整体不需要再改
- **可独立实施**：与 stage 6 完全解耦；本 change 用 MockTelephony 跑真 LLM/ASR/TTS（开发机插耳麦做线下验证）；stage 6 上线后再切真 modem-controller
- **新环境变量**：
  - `ISALES_VOLCENGINE_APP_KEY` / `ISALES_VOLCENGINE_APP_TOKEN`（火山引擎共享）
  - `ISALES_VOLCENGINE_LLM_MODEL`（默认 doubao-pro-32k）
  - `ISALES_VOLCENGINE_ASR_ENDPOINT`（默认官方 wss）
  - `ISALES_VOLCENGINE_TTS_VOICE_ID_DEFAULT`（默认音色，campaign.voice_id 缺失兜底）
  - `ISALES_OPENAI_API_KEY` / `ISALES_OPENAI_BASE_URL`（默认官方）
  - `ISALES_OPENAI_LLM_MODEL`（默认 gpt-4o-mini）
  - `ISALES_ENGINE_TOKEN_BUDGET_PER_CALL`（默认 50000）
  - `ISALES_LIVE_PROVIDER_TESTS`（CI 跳过；本地真接口烟测启用）
- **超出本 change 范围**：modem-controller IPC + 真硬件（stage 6 的 impl-engine-hardware）；阿里云 / 通义 / 智谱 / Anthropic Provider（v2 候选）；录音上传链路（stage 6）；token 预算超限的事件总线（仅日志，事件总线 v2）
