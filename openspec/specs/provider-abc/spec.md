# provider-abc Specification

## Purpose
TBD - created by archiving change init-isales-common. Update Purpose after archive.
## Requirements
### Requirement: Provider ABC 集中定义在 isales-common

ASR / TTS / LLM 三类外部服务的接口契约 SHALL 以抽象基类（ABC）形式集中定义在 `isales-common/providers/` 模块。供应商的真实实现 MUST 继承这些 ABC；其代码 MAY 位于 `isales-engine/providers/`（仅 engine 使用时），但当某真实实现需被一个以上服务（如 isales-engine 与 isales-api）共用时，该实现 SHALL 下沉到 `isales-common/providers/`，由各服务从共享 `CredentialStore` 统一构建，MUST NOT 在消费方各自复制一份 vendor 协议实现。

#### Scenario: 切换供应商不改业务代码

- **WHEN** 需要从供应商 A 切到供应商 B
- **THEN** 仅替换继承 ABC 的真实实现类；任何依赖 ABC 的业务代码（编排、状态机、tools）MUST 不需修改

#### Scenario: 实现类必须继承 ABC

- **WHEN** 引入新的真实供应商实现
- **THEN** 该实现 MUST 继承对应的 ABC 并实现全部抽象方法；MUST NOT 自定义平行接口绕过 ABC

#### Scenario: 跨服务共用的实现下沉 common

- **WHEN** 一个真实供应商实现需被多个服务（如 engine 合成播音 + api 试听合成）调用
- **THEN** 该实现 SHALL 位于 `isales-common/providers/`，各服务从 `isales_common.credentials.CredentialStore` 构建同一实现；MUST NOT 在某一服务内复制等价的 vendor 客户端

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
- **THEN** 调用方 SHALL 传入 `campaign.voice_id`——一个不透明的 vendor speaker 标识字符串（如 `zh_female_xiaohe_uranus_bigtts`），原样透传给 TTS provider；该字符串不在本系统编目（`voice_model` 表已随 `admin-prune-vestigial-features` 删除），ABC 不关心 voice_id 的内部映射；`voice_id` 为空时实现 MAY 回落到 provider 默认音色

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

orchestrator / 实时模块 / 重试调度依赖这套异常分类做降级决策（当前 v1：main LLM 流式异常兜底 / 默认回复；v2 候选：`ProviderRateLimited` 切备 Provider）。

#### Scenario: 超时统一

- **WHEN** 任何 Provider 调用超时
- **THEN** 实现 MUST 抛 `ProviderTimeout`，业务层据此触发 `ai-pipeline` spec 的降级路径（main LLM 流式异常兜底 / 默认回复）

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

### Requirement: ASR Provider 向 vendor 发包遵守 vendor 粒度规格

ASR Provider 的实现在向上游 vendor（流式语音识别服务）发送音频时，MUST 按 vendor 文档规定的单包大小与发包间隔成批发送，MUST NOT 把上游音频源（如 RTC 的 10ms 帧）以远小于规格的粒度逐帧 1:1 转发。

当 vendor 通过静音判停参数（如 `end_window_size`）切句时，发包粒度违规会使该判停形同失效：vendor 把整句 `definite`/最终结果的 finalize 拖到数秒级，并可能触发 vendor 侧的 keepalive/ping 超时而频繁重连。因此 Provider SHALL 在发送前累积到 vendor 推荐的包时长（量级 100–200ms），使每轮用户语音的最终结果 finalize 尾延迟落在亚秒级。

发包粒度是 Provider 与 vendor 之间的实装契约，MUST NOT 因上游音频帧大小变化而违反；上游帧更小时，Provider MUST 在内部缓冲攒包。

#### Scenario: 上游 10ms 帧攒包后再发给 vendor

- **WHEN** 上游以 10ms 一帧的粒度向 ASR Provider 持续推送 PCM
- **THEN** Provider MUST 在内部累积到 vendor 推荐的包时长（~100–200ms）后再发送一包，MUST NOT 每个 10ms 帧各发一包

#### Scenario: 用户说完一句后及时 finalize

- **WHEN** 用户说完一句、随后进入静音，且 vendor 配置了静音判停（`end_window_size`）
- **THEN** vendor SHALL 在亚秒级（与 `end_window_size` 同量级，而非数秒）输出该句的最终结果（`is_final=true` / `definite=true`），使引擎能及时进入下一轮；MUST NOT 因发包过碎而把 finalize 拖到 5–11 秒

### Requirement: ASR 输入静音整形不污染打断检测路径

当引擎为了让 vendor 的静音判停及时触发，而对喂给 ASR 的音频做静音整形（如把句末低能量帧替换为数字静音）时，该整形 MUST 仅作用于喂 ASR vendor 的音频路径，MUST NOT 作用于喂打断检测（barge-in / `interruption-detection`）的音频路径——后者需要原始未整形的信号来判定用户插话。

静音整形 SHALL 带迟滞 / hangover，避免把一句话内部的自然停顿误整形为句末静音而导致 vendor 半句 finalize（碎句）。整形阈值与 hangover SHALL 可配置。

#### Scenario: ASR 路喂静音、VAD 路喂原始

- **WHEN** 引擎对入站音频做句末静音整形以辅助 vendor 判停
- **THEN** 喂 ASR vendor 的那一路 MAY 在句末连续低能量超过 hangover 后被替换为数字静音；喂打断检测的那一路 MUST 始终是原始音频

#### Scenario: 句内停顿不被整形成句末静音

- **WHEN** 用户一句话中间有短暂自然停顿（低于 hangover 时长）
- **THEN** 静音整形 MUST NOT 在该停顿处喂数字静音；MUST NOT 导致 vendor 在句中提前 finalize 产生碎句

### Requirement: TTSProvider 连接复用

TTSProvider 实装 SHOULD 跨多次 `synthesize_stream` 调用复用底层 HTTP 连接（keep-alive 连接池），MUST NOT 每句新建并丢弃整个 client / 连接而无故付重复 TLS 握手。Provider MUST 提供释放底层连接的方式（如 `async def aclose()`），并在进程退出 / provider 弃用时调用。

复用 MUST 对正确性透明：连接半开 / vendor 空闲断连时，实装 SHALL 透明重连（或按现有 `ProviderError` 重试语义处理），调用方行为不变。

#### Scenario: 跨句复用连接

- **WHEN** 同一通话内连续多句调用 `synthesize_stream`
- **THEN** provider SHOULD 复用同一持久 client 的连接池；MUST NOT 每句重建 client 而付一次完整 TLS 握手

#### Scenario: 连接释放

- **WHEN** provider 弃用 / 进程退出
- **THEN** provider MUST 释放其持久连接（`aclose()` 或等价），MUST NOT 泄漏连接

### Requirement: TTSProvider 固定话术缓存

引擎 SHOULD 提供一个缓存层（如装饰 `TTSProvider` 的 `CachingTTSProvider`），对**固定/可复用文本**的 `synthesize_stream(text, voice_id)` 命中即重放已存 PCM，零合成、零网络。缓存 MUST 对正确性透明：命中重放的音频与现合成等价；未命中 MUST 透传 inner provider 并在完整成功后填充缓存。

缓存 MUST 有界（条数 / 总字节上限，LRU 淘汰），MUST NOT 无界增长。缓存键 MUST 含 `voice_id`（换音色自然 miss）。实装 SHOULD 用文本长度阈值区分固定话术（短、缓存）与动态回复（长、不缓存），避免缓存动态 main 回复。缓存 MUST NOT 在合成中途异常 / 被打断时写入（避免半截污染）。

#### Scenario: 固定话术命中零合成

- **WHEN** 同一 `(text, voice_id)` 的固定话术（如开场白）在缓存暖后再次合成
- **THEN** provider SHALL 直接重放已存 PCM，MUST NOT 再发 TTS 合成请求 / 付网络与首字节延迟

#### Scenario: 未命中透传并填充

- **WHEN** `(text, voice_id)` 不在缓存且文本长度在可缓存阈值内
- **THEN** provider SHALL 透传 inner 合成、边播边累积，并在 iterator 完整成功后写入缓存；下次同键命中

#### Scenario: 动态长文本不缓存

- **WHEN** 文本长度超过可缓存阈值（如动态 main LLM 回复）
- **THEN** provider SHALL 直接透传 inner 合成，MUST NOT 写入缓存

### Requirement: LLM 思考/推理模式默认关闭

OpenAI 兼容 LLM Provider（`dashscope` 通义 / `volcengine` 方舟豆包）在构造 `chat` 与 `chat_stream` 的请求 payload 时 SHALL 默认注入「关闭服务端思考/推理（thinking / reasoning）」的供应商参数，使所有角色（main / referee / extractor / restructure）默认走非思考模式。

理由：语音外呼要求低首字延迟。思考模型（DashScope `qwen3.6-flash` / `qwen3.5-plus` 等显式 qwen3 命名默认开思考；Volcengine `doubao-seed-1.6*` 默认开）会在首个 `content` token 之前生成上千个 `reasoning_content` token，这段时间流式 `content` 为空，首音频被迫等到思考结束（实测单轮 10-15s）。没有任何角色需要服务端思考链。

注入 MUST 按 provider 名分支给出确切字段，MUST NOT 按模型名做探测式分支（避免多层兜底）。

#### Scenario: DashScope 默认关思考

- **WHEN** provider 为 `dashscope` 且构造 `chat` 或 `chat_stream` 的请求 payload
- **THEN** payload MUST 含 `enable_thinking=false`（非 OpenAI 标准字段，作为顶层 body 字段发送）

#### Scenario: Volcengine 方舟默认关思考

- **WHEN** provider 为 `volcengine` 且构造 `chat` 或 `chat_stream` 的请求 payload
- **THEN** payload MUST 含 `thinking={"type": "disabled"}`（顶层 body 字段）

#### Scenario: 覆盖所有角色与两条路径

- **WHEN** main 走 `chat_stream`，或 referee / extractor / restructure / main 异常 fallback 走 `chat`
- **THEN** 关思考参数 MUST 在两条路径上同样注入；任一角色 MUST NOT 因继承 vendor 默认而隐式开启思考

#### Scenario: 纯思考模型例外

- **WHEN** 配置了仅支持思考模式、无法关闭的模型（如 `qwq-plus` / `qwen3-*-thinking-*`）
- **THEN** 引擎默认配置 MUST NOT 使用这类模型；若未来某角色确需思考，SHALL 经显式配置（`role_config.ext_params`）开启，而非依赖 vendor 默认（本 change 不实现该开关）

#### Scenario: mock provider 不注入

- **WHEN** provider 为 `mock`（不发 HTTP）
- **THEN** 关思考注入 MUST NOT 适用；mock 行为不变

