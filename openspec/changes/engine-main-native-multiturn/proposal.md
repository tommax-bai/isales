## Why

主对话 (main) 流式 LLM 当前把整通对话拍平成一段文本，塞进**单条** user message（`prompt_builder.py` `_render_dialog` 以 `用户:` / `AI:` 文本前缀区分发言，末行挂 `AI:` 钩子让模型续写）。这是从 referee 旁路分类器的格式误移植到主对话线的——范本 voxen 恰恰相反：主对话线 (`core/llm/chat_history.go` `GetHistory`) 用**原生多轮 chat messages**（role 交替的 user/assistant 数组），只有 referee (`ChatHistoryToString`) 才拍平成文本。chat 模型的对话连贯性是在原生多轮格式上训练/对齐的，喂拍平文本等于退化成文本补全框架，直接表现为对话衔接不自然。

## What Changes

- **BREAKING**（仅引擎内部 prompt 组装，对外 API / DB schema 无影响）：main LLM 的消息组装从「system + 单条拍平 user message」改为「原生多轮 chat messages」。
- `dialog_history` 按 role 逐条 emit 为交替的 `{role:"user"}` / `{role:"assistant"}` message（greeting / ai_reply → assistant，user_speech → user），不再拼成单段文本、不再挂末尾 `AI:` 钩子。
- 【上次通话纪要】+【线索信息】这两段**会话级静态上下文**从 user message 体内移到 system message 末尾的 context 段（它们是上下文不是对话轮次），其余 system append（follow_up / short_reply / wrap_up）顺序与语义不变。
- **不变**：无截断 / 无滑动窗口 / 无摘要，仍喂全量历史；referee 的 `ChatHistoryToString` 拍平格式保持不动（voxen 那条抄对了，本 change 不碰）；main system prompt 内容规范（纯文本输出约束、不输出 JSON）不变；extractor 不变。

## Capabilities

### New Capabilities
<!-- none -->

### Modified Capabilities
- `role-prompt`: 「Prompt 三段式组装」requirement 反转——main LLM MUST 使用标准 chat multi-turn（原生多轮 message 数组），不再用单条拍平 user message；user message 拼接结构 scenario 改为多轮映射规则；【上次通话纪要】注入位置从 user message 改到 system message context 段。「对话过长不做截断」requirement 的无截断语义保留，仅措辞对齐多轮。

## Impact

- 代码：`isales-engine/isales_engine/pipeline/prompt_builder.py`（`build_main_messages` / `_build_user_message` / `_render_dialog` 重写为多轮组装；`build_greeting_messages` 不受影响）。
- 调用点 `pipeline/orchestrator.py`（`chat_stream(messages, ...)` 签名不变，messages 内容变多轮）。
- Provider 层 `llm` chat completion 接口已支持多条 message（referee 早已传 system+user 两条），无需改 provider ABC。
- 测试：`isales-engine` prompt_builder / orchestrator 相关单测需更新断言（从单 user message 改为多轮数组）。
- 无 DB 迁移、无 isales-common 版本变更、无 web / api 改动。
- 真机验收：需对比改前/改后主对话衔接质量（mac dev no-modem smoke + 真人 mic）。
