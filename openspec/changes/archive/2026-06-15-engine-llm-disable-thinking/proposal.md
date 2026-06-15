## Why

OpenAI 兼容 LLM Provider 当前向 vendor 发请求时**从不传任何关闭思考/推理（thinking / reasoning）的参数**，于是 vendor 按它自己的默认值执行。而 DashScope 的 `qwen3.6-flash` / `qwen3.5-plus`（含 `qwen3.6-max` / `qwen3.5-flash` 等显式 qwen3 命名）**默认开启思考**，Volcengine 方舟 `doubao-seed-1.6*` 同样默认开。思考模型在首个 `content` token 之前会先生成上千个 `reasoning_content` token，这段时间流式 `content` 为空 → 引擎 `chat_stream` 无 token 可 yield → 首音频被迫等到思考结束。

实测 call 193（camp1，main=`qwen3.6-flash`、extractor=`qwen3.5-plus`，provider=dashscope）：单轮 `tokens_out` 高达 1663 / 2008（可见回复仅 72 / 83 字 ≈ 50 token，其余全是 reasoning），`first_audio_ms` ≈ `main_duration_ms` ≈ 10.6s / 14.8s。慢的 100% 是服务端思考，与「已用 flash 模型」不矛盾——flash 指参数量小/便宜，不等于关思考。

语音外呼的核心 SLA 是低首字延迟，没有任何角色需要服务端思考链。应在 Provider 层默认关闭思考，使所有角色（main / referee / extractor / restructure）默认走非思考模式。

## What Changes

- OpenAI 兼容 LLM Provider 的 `chat` 与 `chat_stream` 在构造 payload 时 SHALL 按 provider 注入「关思考」参数：
  - `dashscope` → `enable_thinking=false`
  - `volcengine` → `thinking={"type": "disabled"}`
- 该注入对**所有角色统一生效**（main 流式 + referee/extractor/restructure 的 `chat`），因为它们都汇入同一个 `OpenAICompatibleLLMProvider`。`mock` provider 不发 HTTP、不受影响。
- 按 provider 名分支（**不做按模型名探测**，避免多层兜底）；注释注明例外（纯思考模型 qwq-plus / qwen3-*-thinking 不可关）与移除触发条件（未来某角色确需思考时改为读 `role_config.ext_params["thinking"]`）。

## Capabilities

### New Capabilities
- `provider-abc`: 新增「LLM 思考/推理模式默认关闭」requirement——OpenAI 兼容 LLM Provider 默认向 vendor 注入关思考参数，覆盖 `chat` + `chat_stream`，按 provider 给出确切字段。

### Modified Capabilities
<!-- none -->

## Impact

- 代码：仅 `isales-engine/isales_engine/providers/llm_openai_compatible.py`（新增 `_thinking_off_payload()` helper，merge 进 `chat` / `chat_stream` 两处 payload）。
- 测试：`isales-engine` provider 单测新增——用 `httpx.MockTransport` 捕获请求体，断言 dashscope / volcengine 各自的关思考字段出现在 `chat` 与 `chat_stream` 的 payload 中。
- 无 DB 迁移、无 isales-common 版本变更、无 web / api / scheduler / worker 改动（worker 的 LLM 栈 v1 仅 mock provider，不发 HTTP）。
- 部署：scp `llm_openai_compatible.py` 到 ECS + `systemctl restart isales-engine`。
- 真机验收：部署后下一通真实通话的 `pipeline_trace` 应见 `tokens_out` 从 ~1600 降到 ~50、`first_audio_ms` 从 10-15s 降到 ~1-3s。
- **deferred**：volcengine 路径的关思考参数语法已对照 vendor 文档（`thinking.type=disabled`），但火山账号当前无可用豆包模型（见 split-model-and-speech-provider-config），其真机生效未验证；dashscope 路径为当前生产实际使用路径，完整验收。
