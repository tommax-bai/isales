> 实施在 isales-engine 仓库（已存在）。每组对应 1~2 个 PR，按顺序合入。
> 不动 isales-common（v0.1.2 已含 ABC + LLMResponse / ASRResult / Message / FinishReason）。

## 1. ProviderError 体系 + factory 扩展骨架（PR #1）

- [ ] 1.1 `providers/_errors.py`：`ProviderError` 基类 + 4 子类（ProviderTimeout / ProviderRateLimited / ProviderInvalidRequest / ProviderServerError），与 isales-common 对齐
- [ ] 1.2 `providers/_http.py`：共享 httpx.AsyncClient 工厂 + 通用 status → ProviderError 映射函数（429 / 5xx / 4xx / timeout）
- [ ] 1.3 `providers/factory.py`：扩展 build_llm/asr/tts 路由 — `volcengine` / `openai` / `mock`；invalid 仍 NotImplementedError
- [ ] 1.4 settings.py 增 ISALES_VOLCENGINE_APP_KEY / APP_TOKEN / LLM_MODEL / ASR_ENDPOINT / TTS_VOICE_ID_DEFAULT；ISALES_OPENAI_API_KEY / BASE_URL / LLM_MODEL；ISALES_ENGINE_TOKEN_BUDGET_PER_CALL（默认 50000）
- [ ] 1.5 测试：build_llm/asr/tts 各 provider 名都返回正确类型；非法名抛 NotImplementedError
- [ ] 1.6 测试：ProviderError 4 子类层次；映射函数 status → 类的全覆盖

## 2. 火山豆包 LLM Provider（PR #2）

- [ ] 2.1 `providers/llm_volcengine.py`：VolcengineLLMProvider — chat(messages, json_mode, temperature, top_p, max_tokens) → LLMResponse
- [ ] 2.2 鉴权头 + payload 形态按火山豆包 OpenAI-兼容 chat completions endpoint
- [ ] 2.3 json_mode=True → response_format={"type": "json_object"}；非 json_mode 走标准 chat
- [ ] 2.4 解析响应：content / tokens_in / tokens_out / finish_reason / latency_ms
- [ ] 2.5 异常映射：429 → ProviderRateLimited；5xx → ProviderServerError；超时 → ProviderTimeout；4xx → ProviderInvalidRequest；解析错 → ProviderInvalidRequest
- [ ] 2.6 单元测试（httpx.MockTransport）：happy path JSON + 非 JSON / 429 / 500 / 408 timeout / 401 unauth / 解析失败
- [ ] 2.7 可选烟测：`tests/test_real_providers.py::test_volcengine_llm_smoke` 在 ISALES_LIVE_PROVIDER_TESTS=1 跑真 API（CI skip）

## 3. OpenAI LLM Provider（PR #3）

- [ ] 3.1 `providers/llm_openai.py`：OpenAILLMProvider — 同 ABC；支持 base_url override（Azure / 兼容服务）
- [ ] 3.2 json_mode=True → response_format={"type": "json_object"}；模型按 settings.openai_llm_model 默认 gpt-4o-mini
- [ ] 3.3 异常映射：与火山豆包同套 ProviderError 体系
- [ ] 3.4 单元测试（httpx.MockTransport）：完整路径 + base_url override + 鉴权失败
- [ ] 3.5 可选烟测：`tests/test_real_providers.py::test_openai_llm_smoke`

## 4. 火山引擎 ASR Provider（PR #4）

- [ ] 4.1 `providers/asr_volcengine.py`：VolcengineASRProvider 继承 ASRProvider ABC；stream_recognize(audio_chunks) → AsyncIterator[ASRResult]
- [ ] 4.2 内部启动 WebSocket（websockets / wscat 库）连接火山实时识别 endpoint；鉴权头 / 协议帧按官方文档
- [ ] 4.3 入参：8kHz mono PCM 16-bit LE chunks；逐帧推送 ws；同时消费 ws 文本帧（partial / final）
- [ ] 4.4 输出 yield ASRResult(text, is_final, timestamp_ms)；timestamp_ms 以连接建立为 0 起点
- [ ] 4.5 重连：连接异常 / 1006 → 重连 3 次（指数退避 200ms / 400ms / 800ms）；3 次失败 → 抛 ProviderServerError
- [ ] 4.6 取消：消费 audio_chunks 的 task 收到 CancelledError → 优雅 close ws + drain output
- [ ] 4.7 单元测试（fake-ws server in-memory）：partial 序列 + final / 1006 重连 / 鉴权失败 / 协议帧错误
- [ ] 4.8 可选烟测：`tests/test_real_providers.py::test_volcengine_asr_smoke` 用预录 wav 文件喂

## 5. 火山引擎 TTS Provider（PR #5）

- [ ] 5.1 `providers/tts_volcengine.py`：VolcengineTTSProvider 继承 TTSProvider ABC；synthesize_stream(text, voice_id) → AsyncIterator[bytes]
- [ ] 5.2 HTTP 流式拉取（httpx stream context）；首字节即 yield；记录 latency_to_first_byte 到 logger（监控接入）
- [ ] 5.3 8kHz mono PCM 16-bit LE 输出
- [ ] 5.4 失败重试 1 次；最终失败抛 ProviderTimeout / ProviderServerError
- [ ] 5.5 单元测试（httpx.MockTransport stream）：完整流 / 中断 5xx 重试成功 / 重试仍失败 / 首包计时
- [ ] 5.6 可选烟测：`tests/test_real_providers.py::test_volcengine_tts_smoke` 调真 API 写本地 wav 文件人工听感

## 6. SPEAKING 期间实时打断 + audio_out cancel（PR #6）

- [ ] 6.1 `realtime/telephony_client.py`：ABC docstring 加"audio_out 实现 MUST 在 CancelledError 时立即停推剩余 chunks"
- [ ] 6.2 `realtime/mock_telephony.py`：audio_out 实现确保 CancelledError → break async-for；测试覆盖
- [ ] 6.3 `run_loop.py`：增 `_partial_monitor` 后台 task；从 ASR pump 新 channel `asr_partials_q` 消费 partial；状态 SPEAKING / FILLER 时调 evaluate_partial；triggered → cancel `current_speaking_task` + 状态转移
- [ ] 6.4 `run_loop.py`：SPEAKING 任务包成 `current_speaking_task = asyncio.create_task(_play_tts_with_cancel(...))`；CancelledError 路径设置 session.consecutive_interruption_count += 1
- [ ] 6.5 SPEAKING 完整完成（无 cancel）→ session.consecutive_interruption_count = 0
- [ ] 6.6 进入 PROCESSING 时检查 counter ≥ campaign.max_continuous_interruptions：short_reply 策略 → set config.pipeline.short_reply_active=True 后跑常规管线；listen_only 策略 → 跳过 PROCESSING，TTS 播 "您请说" 后回 LISTENING
- [ ] 6.7 transcript 追加 interruption 事件（spec 已定义）；保护策略触发追加 interruption_protection_engaged 自定义事件（待 transcript spec 再 sync 时纳入）
- [ ] 6.8 测试：SPEAKING 期间 ASR partial 触发 → SPEAKING task 被 cancel + 状态 INTERRUPTED → PROCESSING + counter +1
- [ ] 6.9 测试：连续 3 次打断 → short_reply 策略 prompt 临时追加；连续 3 次打断 → listen_only 策略说 "您请说"
- [ ] 6.10 测试：完整 SPEAKING 后 counter 清零
- [ ] 6.11 测试：FILLER 期间打断 → 停 filler audio_out + 进 PROCESSING（与 SPEAKING 同路径）
- [ ] 6.12 contract 测试 `test_telephony_client_contract.py` 增 audio_out cancel 用例

## 7. token 用量监控（PR #7）

- [ ] 7.1 orchestrator `_serialize_candidate` 已写 prompt_tokens / completion_tokens；本 PR 验证真 Provider 返回的 LLMResponse.tokens_in/out 落到 trace（单元测试）
- [ ] 7.2 CallSession 累计 `total_tokens_in / total_tokens_out`（dataclass 增字段）；每条 LLMResponse 在 orchestrator 后增量
- [ ] 7.3 settings.engine_token_budget_per_call（默认 50000）；超限时 WARN 日志含 call_record_id + tokens
- [ ] 7.4 测试：累计准确（多个 LLM 调用相加）；超 budget WARN 路径
- [ ] 7.5 stage 5 留 hook：未来加 EngineEvent.TokenBudgetExceeded（待 isales-common 升 0.1.3）

## 8. 配置切换 + Campaign 级 model（PR #8）

- [ ] 8.1 `providers/factory.py`：build_llm 接受 `model: str | None`，按 model 决定 endpoint（如 model="gpt-4o-mini" → OpenAI；model="doubao-pro" → 火山）；factory 也接受显式 provider 名 override
- [ ] 8.2 orchestrator 已穿透 role.model 字段；本 PR 让 LLMProvider 实现内部按 model 字段选 endpoint / payload
- [ ] 8.3 多 LLM Provider 实例共存：role 用 doubao 而 polish 用 gpt-4o（性价比配置）；orchestrator 已支持每 role 独立 LLMProvider
- [ ] 8.4 测试：build_llm("doubao-pro") 返回 VolcengineLLMProvider 配置正确；build_llm("gpt-4o") 返回 OpenAILLMProvider；mock 不变
- [ ] 8.5 文档：README 部署章节加 model 切换示例

## 9. 真 Provider 端到端验收（PR #9）

- [ ] 9.1 `scripts/fake_dial.py` 已存在；本 PR 增 `--audio-file <wav>` 选项：把 wav 重采样到 8kHz mono PCM 后通过 MockTelephony.inject_user_audio 喂入
- [ ] 9.2 README 添加端到端真 LLM 验收流程：（1）export VOLCENGINE_* / OPENAI_*；（2）切 env 到 volcengine；（3）准备 wav 文件；（4）跑 fake_dial；（5）观察 transcript JSONB / pipeline_trace token 字段 / engine:worker:call-ended 队列
- [ ] 9.3 端到端集成测试（手动 / 半自动）：跑 1 通真 LLM + mock 电话 5 轮对话，验证 goal_achieved / wrap_up / token 累计
- [ ] 9.4 烟测脚本：`scripts/smoke_real_providers.py` 一次性跑 LLM + ASR + TTS 各一次（最低成本验证三套都能 200）
- [ ] 9.5 IMPLEMENTATION_PLAN.md 阶段 5 验收清单全部勾选

## 10. 收尾

- [ ] 10.1 全量 pytest 全绿（mock 套 + provider 单元）
- [ ] 10.2 mypy / ruff 无 error
- [ ] 10.3 端到端验收：fake_dial 注入真 LLM 通话 → 完整 5 轮对话 → goal_achieved → WRAPPING_UP → END → call_record / pipeline_trace（含真 token）/ engine:worker:call-ended 队列正确
- [ ] 10.4 端到端验收：连续打断保护两种策略路径走过；SPEAKING 期间真 partial 触发 cancel + 进 INTERRUPTED 验收
- [ ] 10.5 部署文档更新：env 表新加项 + 真接口烟测说明
- [ ] 10.6 主仓 commit 标记 impl-engine-providers 实施完成；archive 由 /opsx:archive 触发
