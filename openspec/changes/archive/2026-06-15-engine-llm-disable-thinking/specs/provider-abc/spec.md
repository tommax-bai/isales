## ADDED Requirements

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
