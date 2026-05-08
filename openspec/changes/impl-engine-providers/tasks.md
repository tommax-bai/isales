> 实施在 isales-engine 仓库（已存在）。每组对应 1~2 个 PR，按顺序合入。
> 不动 isales-common（v0.1.2 已含 ABC + LLMResponse / ASRResult / Message / FinishReason）。

## 1. ProviderError 体系 + factory 扩展骨架（PR #1）✅

- [x] 1.1 `providers/_errors.py`：从 isales-common 重导出 ProviderError 4 子类 + map_http_error / map_transport_error / as_provider_invalid_response
- [x] 1.2 共享 httpx 工厂逻辑内嵌 _errors.py 的映射函数中（无独立 _http.py）
- [x] 1.3 `providers/factory.py`：扩展路由 + KNOWN_*_PROVIDERS frozenset；非 mock 真实现带凭据检查
- [x] 1.4 settings.py 全新 env 变量已加（VOLCENGINE_* / OPENAI_* / TOKEN_BUDGET_PER_CALL / LIVE_PROVIDER_TESTS）
- [x] 1.5 测试：factory 路由 + 凭据缺失错误信息 + model 参数透传
- [x] 1.6 测试：4 子类映射全路径 + Retry-After / vendor_code 抽取

## 2 + 3. 火山豆包 + OpenAI LLM Provider（合并 PR #2+#3）✅

合并实施：OpenAI 和火山豆包都暴露 OpenAI-兼容的 chat completions endpoint，
一份代码 (`providers/llm_openai_compatible.py`) 通过不同 base_url + api_key
覆盖两个 vendor。

- [x] 2/3.1 OpenAICompatibleLLMProvider — chat(messages, json_mode, temperature, top_p, max_tokens) → LLMResponse
- [x] 2/3.2 鉴权头 + payload + json_mode 走 response_format={"type": "json_object"}
- [x] 2/3.3 解析 content / usage.prompt_tokens / completion_tokens / finish_reason；vendor 未知 finish_reason 兜底为 "stop"
- [x] 2/3.4 异常映射：429 / 5xx / 4xx / 解析失败 / transport timeout 全套 ProviderError
- [x] 2/3.5 10 个 pytest（httpx.MockTransport）：happy path / json_mode / 429 + Retry-After / 5xx / 401 / 缺 choices / 非 JSON / 未知 finish_reason / 真 transport 超时
- [ ] 2/3.6 可选烟测 tests/test_real_providers.py — 用户提供 ISALES_LIVE_PROVIDER_TESTS=1 + 凭据时手动跑（CI 跳过；本 change 不实施真 API 烟测脚本）

## 4. 火山引擎 ASR Provider（PR #4）— DECISION REQUIRED

> **状态：deferred，需要用户决策**。火山引擎实时 ASR WebSocket 协议
> （二进制帧头 + JSON config + audio bytes）需要凭官方 SDK 文档实施；推荐
> 通过 vendor 提供的 SDK（如 volcengine-python-sdk）而非裸 WebSocket。需要
> 用户：
>
> 1. 提供 ISALES_VOLCENGINE_APP_KEY / APP_TOKEN（运营开通账号）
> 2. 决定使用官方 SDK 还是裸 WebSocket（SDK 简化协议处理但增加依赖）
> 3. 如使用 SDK，确认 SDK 包名 + 版本

- [ ] 4.1-4.8 留待用户决策后实施

## 5. 火山引擎 TTS Provider（PR #5）— DECISION REQUIRED

> **状态：deferred**。同 PR #4 — 火山 TTS 也建议通过官方 SDK 接入而非
> 裸 HTTP，需要凭据与 SDK 选型。

- [ ] 5.1-5.6 留待用户决策后实施

## 6. SPEAKING 期间实时打断 + audio_out cancel（PR #6）✅

- [x] 6.1 audio_out 行为已在 stage 4 默认是 cancel-aware（async for 自然 break）；docstring 已更新
- [x] 6.2 MockTelephonyClient.audio_out 通过 contract 测试覆盖 CancelledError
- [x] 6.3 `run_loop._asr_pump` 现在分流 partial / final → 两个 queue；新增 `_partial_monitor` 后台 task 消费 partial
- [x] 6.4 `_play_tts` cancel-aware：把 audio_out 包成 task 写到 session.current_speaking_task；返回 bool 表示是否完整播完
- [x] 6.5 SPEAKING 完整 → counter=0；被 cancel → counter+=1
- [x] 6.6 _decide_protection 在 PROCESSING 入口前判断；listen_only 路径用 _play_tts(interruptible=False) 播保护 cue
- [x] 6.7 interruption transcript 事件由 _partial_monitor 写入；interruption_protection_engaged 暂未单独写（spec sync 时再决策）
- [x] 6.8-6.12 10 个 pytest：_decide_protection 三路径 / _partial_monitor 触发与忽略 / _play_tts cancel 返回 False / e2e SPEAKING 打断 + listen_only 路径

## 7. token 用量监控（PR #7）✅

- [x] 7.1 orchestrator 写 prompt_tokens / completion_tokens 入 pipeline_trace；run_loop 在每轮 PROCESSING 后从最新 trace 累加到 session.total_tokens_in/out
- [x] 7.2 CallSession 增 total_tokens_in / total_tokens_out / _token_budget_per_call 字段
- [x] 7.3 settings.engine_token_budget_per_call（默认 50k）；run_session finally 块超限时 WARN
- [x] 7.4 3 个 pytest：累计准确 / 超预算 WARN 触发 / 不超预算无 WARN
- [x] 7.5 EngineEvent.TokenBudgetExceeded 钩子（待 isales-common v0.1.3 加 schema）— 当前仅日志告警

## 8. 配置切换 + Campaign 级 model（PR #8）— PARTIAL

- [x] 8.1 factory.build_llm 已接 `model` 参数（PR #1）；不传则用 settings 默认
- [ ] 8.2 orchestrator 改为按 role.model 调用 build_llm 创建 per-role LLMProvider — DEFERRED：需要 orchestrator 较深重构（当前接受单 LLMProvider 实例），且要先决策 PR #4/#5 后再统一接入
- [ ] 8.3 多 LLM Provider 实例共存（role / polish 不同 vendor）— DEFERRED 同上
- [ ] 8.4 测试 build_llm 多 model — 已部分覆盖（test_build_llm_with_explicit_model_override）
- [ ] 8.5 文档 README 加 model 切换示例 — DEFERRED

## 9. 真 Provider 端到端验收（PR #9）— DEFERRED

> 依赖 PR #4 / PR #5 真 Provider 凭据 + 实施。

## 10. 收尾（PR #10）

- [x] 10.1 全量 pytest 全绿（148 个）
- [x] 10.2 mypy / ruff 无 error
- [ ] 10.3 端到端真 Provider 验收 — DEFERRED（依赖 PR #4 / #5）
- [x] 10.4 实时打断 + listen_only / short_reply 保护单元 + e2e 测试已通过（PR #6）
- [x] 10.5 README .env.example 已含新 env 变量；真接口烟测启用方法 doc 已写
- [ ] 10.6 archive 待 PR #4 / #5 决策后由 /opsx:archive 触发，或局部 archive 当前完成部分
