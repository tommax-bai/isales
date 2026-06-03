## MODIFIED Requirements

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

## ADDED Requirements

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
