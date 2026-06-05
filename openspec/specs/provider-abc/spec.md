# provider-abc Specification

## Purpose
TBD - created by archiving change init-isales-common. Update Purpose after archive.
## Requirements
### Requirement: Provider ABC 集中定义在 isales-common

ASR / TTS / LLM 三类外部服务的接口契约 SHALL 以抽象基类（ABC）形式集中定义在 `isales-common/providers/` 模块；`isales-engine` 的真实实现 MUST 继承这些 ABC。

#### Scenario: 切换供应商不改业务代码

- **WHEN** 需要从供应商 A 切到供应商 B
- **THEN** 仅 `isales-engine/providers/` 下的实现类替换；任何依赖 ABC 的业务代码（编排、状态机、tools）MUST 不需修改

#### Scenario: 实现类必须继承 ABC

- **WHEN** 在 isales-engine 引入新的真实供应商实现
- **THEN** 该实现 MUST 继承对应的 ABC 并实现全部抽象方法；MUST NOT 自定义平行接口绕过 ABC

### Requirement: ASR Provider 异步流式接口

ASRProvider SHALL 暴露异步流式识别接口：输入音频 chunk 流，输出识别结果流（含中间结果与最终结果标记）。

#### Scenario: 流式输入输出

- **WHEN** 调用 `stream_recognize(audio_chunks)`
- **THEN** 接口 MUST 以 `AsyncIterator[ASRResult]` 返回；`ASRResult` 字段包括 `text`（当前文本）、`is_final`（是否为本句最终结果）、`timestamp_ms`

#### Scenario: 中间结果驱动打断检测

- **WHEN** 引擎在 LISTENING 状态接收音频
- **THEN** ASRProvider MUST 持续推送中间结果（`is_final=false`），便于 `interruption-detection` 即时判定；MUST NOT 仅在句末才返回

### Requirement: TTS Provider 异步流式合成接口

TTSProvider SHALL 暴露异步流式合成接口：输入文本与音色，输出 PCM 音频字节流（首包尽快返回以降低端到端延迟）。

#### Scenario: 流式输出首包

- **WHEN** 调用 `synthesize_stream(text, voice_id)`
- **THEN** 接口 MUST 以 `AsyncIterator[bytes]` 返回 PCM chunks；首包 SHALL 在 500ms 内开始返回（依赖供应商能力，ABC 不强制超时但实现应自测）

#### Scenario: 音色由 voice_id 选择

- **WHEN** 调用合成
- **THEN** 调用方 SHALL 传入 `voice_model.voice_id`（来自 `data-model` spec 的 voice_model 表）；ABC 不关心 voice_id 的内部映射

### Requirement: LLM Provider chat 接口与 JSON Mode

LLMProvider SHALL 暴露 `chat` 方法，参数 MUST 包含 `messages` / `json_mode` / `temperature` / `top_p` / `max_tokens`；`json_mode=True` 时实现 MUST 启用对应供应商的 JSON Mode 或等效约束。`chat` 是 **non-streaming** 接口，返回完整 `LLMResponse` 后调用方才能继续；本接口 SHALL 仍是 referee LLM、extractor LLM、开场白 LLM、main LLM 异常 fallback 路径的入口（详见 `ai-pipeline` spec § "main LLM streaming 异常一次性 fallback"）。

#### Scenario: JSON Mode 强制启用

- **WHEN** 调用 `chat(..., json_mode=True)` 且供应商支持 JSON Mode
- **THEN** 实现 MUST 启用该模式；返回内容 SHALL 是合法 JSON 字符串

#### Scenario: 供应商不支持 JSON Mode

- **WHEN** 调用 `chat(..., json_mode=True)` 但供应商无原生 JSON Mode
- **THEN** 实现 MUST 用 system prompt + 后处理校验等等效手段保证输出为 JSON；MUST NOT 静默忽略 `json_mode` 参数

#### Scenario: 普通对话

- **WHEN** 调用 `chat(..., json_mode=False)`
- **THEN** 接口返回 `LLMResponse`，字段包括 `content`（文本）、`tokens_in` / `tokens_out`（计费用）、`finish_reason`、`latency_ms`

### Requirement: 统一错误模型

三类 Provider 的实现 SHALL 把供应商原生异常包装为 `ProviderError` 体系（基类 + 子类：`ProviderTimeout` / `ProviderRateLimited` / `ProviderInvalidRequest` / `ProviderServerError`）；MUST NOT 让供应商 SDK 原生异常直接抛到业务层。

每种异常子类的触发条件 SHALL 严格按以下硬契约（本 Requirement 把"哪种 HTTP / 协议响应触发哪类异常"从隐式约定提升为硬契约）：

| 触发条件 | 抛出 |
|---|---|
| HTTP 429 / 协议层限流 | `ProviderRateLimited` |
| HTTP 5xx / 连接错误 / DNS 失败 / SSL 错误 / WebSocket 1006 / WebSocket 服务端关闭 | `ProviderServerError` |
| 请求超时（asyncio.timeout / read timeout / 连接 timeout） | `ProviderTimeout` |
| HTTP 400 / 401 / 403 / 422 / 其他 4xx（非 429） | `ProviderInvalidRequest` |
| 响应非 JSON / JSON 缺必填字段 / 格式不符合 Provider 契约 | `ProviderInvalidRequest` |

orchestrator / 实时模块 / 重试调度依赖这套异常分类做降级决策（当前 v1：候选淘汰 / 默认回复兜底；v2 候选：`ProviderRateLimited` 切备 Provider）。

#### Scenario: 超时统一

- **WHEN** 任何 Provider 调用超时
- **THEN** 实现 MUST 抛 `ProviderTimeout`，业务层据此触发 `ai-pipeline` spec 的降级路径（润色失败兜底 / 默认回复）

#### Scenario: 限流统一

- **WHEN** 供应商返回 429
- **THEN** 实现 MUST 抛 `ProviderRateLimited`，业务层据此决策重试或切换 Provider

#### Scenario: 服务端错误统一

- **WHEN** 供应商返回 5xx，或 HTTP 连接 / WebSocket 出现网络层错误（含 1006）
- **THEN** 实现 MUST 抛 `ProviderServerError`；业务层 MAY 重试（webhook-callback / asr 重连等场景），但不能假设可恢复

#### Scenario: 非法请求统一

- **WHEN** 供应商返回 4xx（非 429），或响应体不符合契约（缺字段 / 类型错）
- **THEN** 实现 MUST 抛 `ProviderInvalidRequest`；业务层 MUST NOT 重试（请求本身有问题，重试无意义），SHALL 走兜底

#### Scenario: SDK 原生异常隔离

- **WHEN** 供应商 SDK / httpx / websockets 抛原生异常
- **THEN** 实现 MUST 在 `try/except` 中转换为 `ProviderError` 子类后再抛；MUST NOT 让原生异常逃出 Provider 实现层

### Requirement: Provider ABC 契约可被 mock 测试

isales-common SHALL 提供 Provider ABC 的 mock 实现与 pytest fixture，便于 `isales-engine` 的单元/集成测试不依赖真实供应商。

#### Scenario: mock 用于本地与 CI

- **WHEN** isales-engine 跑单元测试
- **THEN** 可直接从 `isales_common.providers.testing` 导入 `MockASRProvider` / `MockTTSProvider` / `MockLLMProvider`，配置为输入 → 固定输出

### Requirement: ABC 接口稳定性

Provider ABC 的方法签名 SHALL 视作公共 API；任何破坏性变更 MUST 经 OpenSpec change proposal，并在变更说明中评估对所有真实实现的影响。

#### Scenario: 新增可选参数

- **WHEN** 需要扩展 ABC 方法
- **THEN** SHALL 优先用带默认值的关键字参数，避免破坏现有实现

#### Scenario: 破坏性修改

- **WHEN** 必须修改方法签名或语义
- **THEN** MUST 经 change proposal；MUST 同步升级 isales-engine 中所有实现并通过契约测试

### Requirement: LLM Provider 流式 chat_stream 接口

LLMProvider SHALL 新增 `chat_stream(messages, *, temperature, top_p, max_tokens) -> AsyncIterator[str]` 方法。每次 yield 一个文本 delta（token / chunk）。本接口是 main LLM 的核心入口，必须支持 vendor 的 SSE `stream=true` 协议（OpenAI 兼容协议 / 字节方舟 / 阿里通义 / Volcengine 等）。本接口 MUST NOT 接受 `json_mode` 参数（streaming 与 JSON Mode 冲突，详见 `role-prompt` spec § "main system prompt 内容规范"）。

#### Scenario: 流式 token yield

- **WHEN** 调用 `async for chunk in provider.chat_stream(messages, ...)`
- **THEN** provider MUST 把 vendor SSE 每一个 `delta.content`（文本 token）作为 str yield；流结束时 AsyncIterator 自然终止
- **AND** provider MUST NOT 缓冲 token 等聚合（破坏 streaming 语义）

#### Scenario: 中途异常映射

- **WHEN** chat_stream 在迭代过程中 vendor 断流 / 5xx / 超时
- **THEN** provider MUST 在 yield 之间抛 `ProviderError` 子类（`ProviderTimeout` / `ProviderServerError` / `ProviderInvalidRequest`），跟 `chat()` 同分类硬契约；异常 MUST 在 `async for` 循环中被业务层 catch 走 chat() fallback 路径

#### Scenario: token 计费

- **WHEN** chat_stream 结束（自然结束或异常）
- **THEN** provider MUST 暴露 `last_call_tokens_in` / `last_call_tokens_out` / `last_call_finish_reason` 属性供业务层读取写 pipeline_trace；MUST NOT 把计费信息塞进 yield 的 str（破坏类型契约）

#### Scenario: 重连一次

- **WHEN** chat_stream 在 first token 到达之前 vendor 网络层一次性失败（dns / TLS / connect timeout）
- **THEN** provider MAY 自动重连一次后再抛异常；连接已建立后 SSE 中途断流 MUST NOT 自动重连（避免重复 token 进 TTS）

#### Scenario: vendor 不支持 streaming 的兼容性

- **WHEN** Campaign 配置的 main LLM provider 不支持 streaming（极少见，但 dashscope-text 某些 model 缺）
- **THEN** provider MUST 在 `chat_stream` 实现内部用 `chat()` 一次性调用 + 单次 yield 整段 content；MUST NOT 抛 NotImplementedError；该兜底 MUST 在 provider 自身日志标 `single_yield_fallback=true` 供监控

