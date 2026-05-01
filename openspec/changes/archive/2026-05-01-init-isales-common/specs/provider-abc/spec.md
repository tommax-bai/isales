## ADDED Requirements

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

LLMProvider SHALL 暴露 `chat` 方法，参数 MUST 包含 `messages` / `json_mode` / `temperature` / `top_p` / `max_tokens`；`json_mode=True` 时实现 MUST 启用对应供应商的 JSON Mode 或等效约束（满足 `ai-pipeline` spec 对角色 LLM 的强制 JSON 输出要求）。

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

#### Scenario: 超时统一

- **WHEN** 任何 Provider 调用超时
- **THEN** 实现 MUST 抛 `ProviderTimeout`，业务层据此触发 `ai-pipeline` spec 的降级路径（润色失败兜底 / 默认回复）

#### Scenario: 限流统一

- **WHEN** 供应商返回 429
- **THEN** 实现 MUST 抛 `ProviderRateLimited`，业务层据此决策重试或切换 Provider

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
