## Context

`isales-engine` 主对话 (main) 流式 LLM 现状（`isales_engine/pipeline/prompt_builder.py`）：

- `build_main_messages()` 返回固定两条 message：`[system, user]`。
- `_build_user_message()` 把【上次通话纪要】+【线索信息】+`_render_dialog()` 三段用 `\n\n` 拼成**一个** user message 的 content。
- `_render_dialog()` 遍历 `session.dialog_history`（`list[DialogTurn{role,text,ts_ms}]`），每行加 `用户:` / `AI:` 文本前缀，末尾再补一行 `AI:` 作为续写钩子。
- 代码注释与 `role-prompt` spec 明文「不使用标准 chat multi-turn」。

调用点 `pipeline/orchestrator.py` 把这两条 message 直接喂给 `self._main_llm.chat_stream(messages, ...)`。provider 层底层走 OpenAI 兼容 chat completion（referee 早已传 `[system, user]` 两条 message，说明多条 message 通路已通）。

范本 voxen（`~/codes/voxen-main`）的对照（已实证）：主对话线 `core/llm/chat_history.go:GetHistory()` 拼 `[]ChatMessage{system, ...history(role 交替), user}` 原生多轮，经 `ToOpenAIMessages()` 转 `SystemMessage/UserMessage/AssistantMessage`；只有 referee `llm_referee.go:ChatHistoryToString()` 才把历史拍平成文本。iSales 把 referee 的拍平格式误用到了主对话线。

`DialogTurn.role` 已是 `"user"` / `"assistant"` 两值（`call_session.py`：user_speech→user，greeting/ai_reply→assistant），与 chat message role 一一对应，无需新增映射表。

## Goals / Non-Goals

**Goals:**
- main LLM 收到原生多轮 chat messages（system + user/assistant 交替），对齐 voxen 主对话线与 chat 模型训练分布，改善对话衔接。
- 改动收敛在 `prompt_builder.py` 一个文件 + 其单测；调用点签名、provider ABC、DB、common、web、api 全部不动。

**Non-Goals:**
- 不动 referee 的拍平格式（voxen 那条抄对了，referee 是单 token 分类器，拍平无害且省 token）。
- 不引入截断 / 滑动窗口 / 摘要（无截断语义保持不变）。
- 不改 main system prompt 内容规范（纯文本输出、不输出 JSON）。
- 不动 extractor、不动 `build_greeting_messages`（开场白仍是 system + 单 user 任务指令，无历史）。

## Decisions

**决策 1：dialog_history 直接映射为多轮 message，role 一一对应。**
`for turn in session.dialog_history: messages.append(Message(role=turn.role, content=turn.text))`。因 `DialogTurn.role` 已是 `user`/`assistant`，无需翻译。greeting 作为首条 assistant message 自然进入历史。
- 备选（弃）：维持文本前缀但拆 message——无意义，前缀本就是为单 message 设计。

**决策 2：会话级静态上下文（上次通话纪要 + 线索信息）移入 system message 末尾，不进对话轮次。**
这两段是上下文而非对话发言；若塞成一条 user message 夹在历史前，会污染 role 交替（出现连续两条 user 或让模型误以为客户说了线索信息）。voxen 也把变量经 `configVarFormat` 注入 system prompt。
- 备选（弃）：作为首条 user message——破坏 user/assistant 交替，且语义错位（线索信息不是客户说的话）。

**决策 3：删除末尾 `AI:` 续写钩子。**
原 `AI:` 钩子是文本补全框架的产物。多轮格式下，数组最后一条是最新 user message，chat 模型据 chat completion 协议自然生成下一条 assistant——无需也不应再挂钩子。

**决策 4：system message 段落顺序固定。**
`system_prompt 主体` → follow_up append → short_reply append → wrap_up append（保持 wrap_up MUST 最末的既有约束）→ 会话级 context 段（上次通话纪要 / 线索信息）。context 段放在所有指令之后，作为"参考资料"呈现，不干扰指令优先级。

**决策 5：messages 类型与调用点不变。**
`build_main_messages()` 仍返回 `list[Message]`，`orchestrator.py` 的 `chat_stream(messages, ...)` 调用签名一字不改，只是 list 长度从 2 变为 `2 + len(dialog_history)`。

## Risks / Trade-offs

- **[首轮空历史]** → greeting 由 `build_greeting_messages` 单独生成（不走本路径）；首条真正的 main 调用发生在用户首次说话后，此时 dialog_history 至少含 greeting(assistant)+user_speech(user)，交替正常。需单测覆盖"仅 greeting 无 user"与"空 history"边界，确保不产生空 content message。
- **[连续同 role]** → 理论上若引擎逻辑产生连续两条 user_speech（无 AI 介入），多轮数组会出现连续 user message。多数 chat API 容忍，但部分 provider 严格。缓解：保持原样传入（voxen 也不合并主线连续同 role），如遇 provider 报错再加合并；先不预防性加层（避免多层兜底）。
- **[token 计费/顺序]** → 多轮与拍平的 token 量基本相同（内容一致），不显著改变成本。无截断语义不变。
- **[回归对话质量评估主观]** → 衔接改善需真机对比验证，非纯单测可证。缓解：mac dev no-modem smoke + 真人 mic，改前/改后同 campaign 同话术对比。

## Migration Plan

1. 改 `prompt_builder.py`：重写 `build_main_messages` / `_build_user_message`（拆分为 system-context 拼装 + 多轮 dialog 映射），删 `_render_dialog` 的文本拼接路径（或保留仅供 referee/transcript 复用——确认无其他引用后再删）。
2. 更新 `prompt_builder` / `orchestrator` 单测断言：从「断言单 user message 文本含某子串」改为「断言多轮数组结构 + 各 turn role/content」。
3. `cd ../isales-engine && .venv/bin/python -m pytest -q` 全绿。
4. scp 部署 engine 到 ECS + `systemctl restart isales-engine`（参照既有 scp 部署纪律，不走 git pull）。
5. 真机验收：mac dev no-modem smoke（先重启 engine 防 bug2 冻死）+ 真人 mic 对比衔接。
6. **回滚**：纯引擎单文件改动，git revert + scp 旧文件 + restart 即回滚，无 DB / 无 common 版本牵连。

## Open Questions

- `_render_dialog` 的 `用户:`/`AI:` 文本渲染除 main 外是否还有调用方（transcript 序列化 / pipeline_trace）？apply 时 grep 确认；若有则保留函数仅供他用，main 不再调用它。
