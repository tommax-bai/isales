## Context

阶段 5 的 isales-engine 真 Provider 接入。stage 4 已经把状态机 / 三层管线 / 实时模块 / dial / event publish/control / finalize_session 全部跑通，所有 LLM/ASR/TTS Provider 都是 mock + MockTelephony。本 change 把 mock 升级为真 Provider 并补完 SPEAKING 期间实时打断（stage 4 在 docstring 中明确标注的 follow-on）。

约束：

- Python 3.11+ 一致
- 全 asyncio
- v1 选 1 套真实供应商：火山引擎家族（ASR + TTS + LLM 豆包）+ OpenAI 备选 LLM
- 不动 isales-common（v0.1.2 已有 Provider ABC + LLMResponse / ASRResult / Message 等）
- 真硬件接入（modem-controller IPC + 8kHz GSM 音频）留 stage 6
- 用 MockTelephony 跑真 Provider 即可验收（开发机插耳麦或用预录 wav 文件喂 audio_in）

## Goals / Non-Goals

**Goals:**

- 真 LLM Provider：火山豆包 + OpenAI 各 1 套，原生 JSON Mode
- 真 ASR Provider：火山豆包 WebSocket 流式（spec 默认）
- 真 TTS Provider：火山引擎流式合成
- 统一 ProviderError 分类（429 / 5xx / timeout / 4xx / 解析失败 → 4 个子类）
- factory 按 settings 路由 + Campaign role.model 字段穿透
- token 用量进 pipeline_trace
- run_loop SPEAKING 期间实时打断（partial monitor + audio_out cancel）
- 连续打断保护（counter + short_reply / listen_only 策略）
- pytest：每 Provider httpx.MockTransport / fake-ws 隔离单测；run_loop 实时打断 e2e；可选真 API 烟测（CI 跳过）

**Non-Goals:**

- 阿里云 / 通义 / 智谱 / Anthropic（v2）
- modem-controller IPC + RealTelephonyClient（stage 6）
- 录音上传 OSS（stage 6 modem-controller 写 wav 后 worker 上传）
- 多 Provider 同时启用 + 跨 Provider 容错切换（v2）
- token 预算超限事件总线（本 change 只日志）
- prompt 缓存 / 半流式 LLM（v2 优化项）
- 自适应 Provider 选择（按延迟 / 成本动态切）

## Decisions

### 1. 火山引擎家族优先 + OpenAI 兜底

- **选择**：默认全栈火山（ASR / TTS / LLM 豆包）；OpenAI 仅 LLM 备选（用户已有 key）；阿里云 / 通义 / 智谱 / Anthropic 全部 NotImplementedError 留 v2
- **理由**：
  - provider-abc spec § "v1 默认 ASR Provider" 明确火山豆包
  - 同家族 ASR + TTS + LLM 减少 vendor 数量、统一鉴权 / 监控 / 计费
  - OpenAI 只接 LLM 因为它没有中文 ASR / TTS 主流方案
- **替代**：全 OpenAI → 中文 ASR/TTS 拉胯；多 vendor 混搭 → 维护成本高；自研 ASR/TTS → v1 时间不够

### 2. 流式 ASR：WebSocket + 持久连接 / per-call

- **选择**：火山豆包 ASR WebSocket，每通通话独立连接；engine `_asr_pump` task 内部启 ws；通话 END 时 close
- **理由**：
  - WebSocket 是火山官方流式 API 主推
  - per-call 连接而非全局长连可避免跨 call 数据交叉；连接建立 < 200ms 在 v1 可接受
  - 与现有 `ASRProvider.stream_recognize(audio_chunks) -> AsyncIterator[ASRResult]` ABC 自然契合：实现内部把 WebSocket 接收循环转成 AsyncIterator yield
- **替代**：HTTP long-poll → 延迟更高；全局共享 ws 多路复用 → 协议复杂、调试痛苦

### 3. 流式 TTS：首包 < 500ms 目标 + 异常重试 1 次

- **选择**：火山引擎流式 TTS API；`synthesize_stream(text, voice_id) -> AsyncIterator[bytes]` 实现内部启动 HTTP 流式拉取，首字节即 yield；超时 / 5xx → 重试 1 次（避免 LLM reply 已生成但 TTS 卡）
- **理由**：
  - spec § Scenario "流式输出首包" 要求 500ms
  - 重试 1 次平衡用户感知卡顿与系统稳定（>1 次重试用户已经听到尾音空白）
  - 仅 stream-level 重试，单字节失败不重试
- **替代**：非流式 → 反应慢；多次重试 → 失败暴露太晚

### 4. LLM Provider：原生 JSON Mode 优先

- **选择**：
  - 火山豆包：调用方传 `response_format={"type": "json_object"}`（API 已支持）
  - OpenAI：同上
  - 不支持的 Provider（v2 接入时）：role-prompt spec § Scenario "文本约束兜底"——prompt 末尾贴 schema 文本 + 后处理 json_parser
- **理由**：
  - role-prompt spec § "JSON Mode 强制策略（两步保护）"
  - stage 4 mock LLM 已模拟 JSON 解析两步兜底，json_parser 已经能处理非严格 JSON
- **替代**：自定义 grammar / function calling → vendor 间不一致；不强制 JSON → 解析失败率高

### 5. ProviderError 体系：硬分类（spec delta 落硬契约）

- **选择**：
  - 429 → `ProviderRateLimited`
  - 5xx / 连接错误 / DNS / SSL 错误 → `ProviderServerError`
  - asyncio.timeout / read timeout → `ProviderTimeout`
  - 401 / 403 / 400 / 422 / 其他 4xx → `ProviderInvalidRequest`
  - 响应非 JSON / JSON 缺字段 → `ProviderInvalidRequest`（响应不符契约）
- **理由**：
  - orchestrator 已经按 stage 4 把"超时 / Provider 异常"统一处理为候选淘汰；增加细分类后未来 stage 6 可针对 `ProviderRateLimited` 做切 Provider 而不是只兜底
  - spec § "统一错误模型" 已定义 4 类，本 change 把"哪种 HTTP 响应触发哪类"硬契约化
- **替代**：让 SDK 异常透传 → orchestrator 处理面爆炸；只一类 ProviderError → 失去切换决策依据

### 6. SPEAKING 期间实时打断：并行 partial monitor + audio_out cancel

- **选择**：
  - 在 `_main_turn_loop` 启动一个 `_partial_monitor` 后台 task：从 ASR pump 的 partial channel（新增 `asr_partials_q`）消费每个 partial，调 `evaluate_partial`
  - SPEAKING 启动时记 `speech_started_ts_ms`；session 内 `current_speaking_task: asyncio.Task | None`
  - 监听到 verdict="triggered"：cancel `current_speaking_task` → cancel 通过 audio_out 内部传播（TelephonyClient `audio_out` 实现 MUST 在 CancelledError 时立即停推 chunks）→ 状态 SPEAKING → INTERRUPTED → PROCESSING（用 ASR final 文本）
  - 不可撤销：进 INTERRUPTED 后 partial_monitor MUST NOT 再触发
  - 完整轮次 SPEAKING 完整完成（无 cancel）→ counter 清零
- **理由**：
  - interruption-detection spec § 双条件 / 不可撤销 / 连续打断
  - 把"打断"做成 cancel-driven 而不是状态机轮询，符合 asyncio 习惯
- **替代**：定时 polling partial → 延迟高；Reactive Streams 框架 → 引入新依赖

### 7. 连续打断 counter：在 _main_turn_loop 维护

- **选择**：
  - SPEAKING 进入时不动 counter；SPEAKING 完整完成 → `session.consecutive_interruption_count = 0`
  - SPEAKING 被 cancel（打断）→ `session.consecutive_interruption_count += 1`
  - 进入 PROCESSING 时检查：counter ≥ `campaign.max_continuous_interruptions` →
    - `short_reply` 策略：set `config.pipeline.short_reply_active=True`（prompt_builder 已支持），调常规 PROCESSING；reply 简短，更可能完整播完
    - `listen_only` 策略：跳过 PROCESSING，TTS 播 "您请说" 后回 LISTENING
  - 触发保护策略时 transcript 追加 `interruption_protection_engaged` 事件（新增 transcript event type 可选，stage 5 留待 sync 决策）
- **理由**：spec 要求保护策略由 campaign 配置决定，counter 只是触发器
- **替代**：每轮 PROCESSING 都查 counter → 性能微差；按时间窗口（5s 内 N 次）→ 复杂度高

### 8. TelephonyClient.audio_out 必须 cancel-aware

- **选择**：ABC docstring 强调实现 MUST 在 CancelledError 时立即停推；MockTelephonyClient 已经基本满足（async for 自然 break）；stage 6 RealTelephonyClient 实现时 MUST 加显式 sentinel
- **理由**：实时打断的 cancel 必须能中断 audio 流送出
- **替代**：用单独的 `cancel_audio_out(call_id)` 方法 → ABC 表面积膨胀；不强制 → 卡声

### 9. token 用量：pipeline_trace 已有字段，本 change 填值

- **选择**：orchestrator 的 `_serialize_candidate` 已经把 `prompt_tokens / completion_tokens` 写入 trace；只需让 Provider 的 LLMResponse 真实回填 tokens；累计超 `ISALES_ENGINE_TOKEN_BUDGET_PER_CALL` → WARN 日志 + 后续可加 EngineEvent
- **理由**：监控接入 0 改动 schema，只换 mock → real 数据
- **替代**：另起 token_usage 表 → 重复持久化；不监控 → 成本失控

### 10. 火山引擎鉴权：env-only

- **选择**：`ISALES_VOLCENGINE_APP_KEY` + `ISALES_VOLCENGINE_APP_TOKEN`（双因子，火山官方）；engine 启动时一次读取，session 内复用；轮转密钥需重启服务
- **理由**：与 isales-api / scheduler / worker 共享密钥源（env + EnvironmentFile）；不引入 secrets manager（v2 候选）
- **替代**：DB 表存密钥 → 多副本同步问题；HSM → v1 不需要

### 11. OpenAI 兼容层：`base_url` 可换

- **选择**：`ISALES_OPENAI_BASE_URL`（默认 `https://api.openai.com/v1`）支持指向 Azure OpenAI / 私有部署 / 第三方兼容服务；调用形态保持一致
- **理由**：Azure OpenAI 与 OpenAI 唯一差异是 endpoint + API key header；本设计支持两者
- **替代**：单独 azure_openai 实现 → 90% 代码重复

### 12. 真接口烟测可选

- **选择**：`tests/test_real_providers.py` 在 `ISALES_LIVE_PROVIDER_TESTS=1` 才跑；CI 默认不启；本地开发者校验真接入用
- **理由**：CI 不持密钥；真接口测试容易因网络 / 限额波动；不能挡 PR
- **替代**：永远不跑 → 真接入 bug 暴露晚；CI 永远跑 → 不稳定

### 13. 不实现"自适应 Provider 切换"

- **选择**：单通通话从开始到结束用一套 Provider；某 Provider 失败 → 走默认回复（stage 4 兜底）；下次通话仍用同一 Provider
- **理由**：跨 Provider 切换需要语义对齐（goal_type / extracted 字段一致），v1 不值得；监控告警足够运维介入
- **替代**：失败时切备 Provider → 实现复杂、调试痛；多 Provider 投票 → 成本翻倍、收益不明

### 14. 真 ASR 8kHz vs 模拟 16kHz

- **选择**：火山豆包 ASR 支持 8kHz 单声道 16-bit LE PCM；MockTelephony / 测试默认 8kHz；stage 6 modem-controller PCM 通道也是 8kHz（GSM 标准）
- **理由**：vendor 一致；audio_in 不需要重采样
- **替代**：16kHz → 需要重采样模块；多采样率自适应 → v2 复杂度

## Risks / Trade-offs

| 风险 | 缓解 |
|---|---|
| 火山豆包 ASR WebSocket 不稳定（中断 / 限流） | 重连 3 次带退避；3 次失败 → ProviderServerError → run_loop 走 no_progress_timeout 兜底；监控连接成功率与 partial 间隔 |
| LLM 总延迟（角色 + 裁判 + 润色 ≈ 12s 最坏）超过用户耐心 | filler 覆盖；运营调小单 LLM timeout（settings `ISALES_ENGINE_PIPELINE_DEFAULT_TIMEOUT_MS` 默认 8000）；real-world 验收时若发现尾延迟超 10s 调 6000 |
| TTS 首包延迟 > 1s 让用户听到 reply 前空白 | 火山官方目标 < 500ms；监控接入；超阈值告警；不在 ABC 强制 |
| token 成本失控（豆包按 token / OpenAI 按 token） | pipeline_trace 累计；call 级 budget 默认 50k tokens（含三层 PK）；超限 WARN |
| 真接口测试不稳定 | CI 跳过；本地用 ISALES_LIVE_PROVIDER_TESTS=1 启用；httpx.MockTransport 单测覆盖 |
| 火山豆包 / OpenAI JSON Mode 偶发不严格 JSON | json_parser 已两步兜底（stage 4 已实现）；解析失败候选淘汰；不重试 LLM |
| audio_out cancel 行为各 TelephonyClient 实现不一致 | tests/test_telephony_client_contract.py 增加 cancel-during-audio-out 契约测试；MockTelephonyClient + stage 6 RealTelephonyClient 都跑 |
| 实时打断在 ASR 中间结果抖动时误打断 | min_duration_ms（默认 800ms）+ 白名单双条件已在 stage 4 实现；本 change 直接复用 |
| 火山豆包 LLM 偶发 8s 内不返回（运营时段 / 模型热点） | 单角色 8s timeout；orchestrator 候选淘汰；候选全淘汰 → default_reply（stage 4 测试覆盖） |
| OpenAI base_url 配错 → 401 → ProviderInvalidRequest | 启动时 `factory.build_llm("openai")` 不预热；首次失败立即暴露；不在 ABC 加 health-check（v2 候选） |
| stage 6 RealTelephonyClient 加入后 audio_out 频率 / chunking 与 stage 4 mock 差异 | contract 测试 + stage 6 联调时校准；本 change 不预先 over-engineer |

## Migration Plan

不适用——provider 切换由 env 控制，不动 DB schema。

部署：

1. 配 `ISALES_VOLCENGINE_APP_KEY` / `ISALES_VOLCENGINE_APP_TOKEN`（运营开通账号后填）
2. （可选）配 `ISALES_OPENAI_API_KEY` 作为 LLM 备选
3. 切 env：`ISALES_ENGINE_LLM_PROVIDER=volcengine` / `ISALES_ENGINE_ASR_PROVIDER=volcengine` / `ISALES_ENGINE_TTS_PROVIDER=volcengine`
4. 重启 isales-engine：`systemctl restart isales-engine`
5. 验收：`python -m scripts.fake_dial --campaign-id <id>` 注入；MockTelephony.inject_user_audio 喂预录 8kHz wav；观察 transcript / pipeline_trace 真 token 用量
6. 回滚：env 切回 `mock` 即可，不影响 DB / Redis 状态

## Open Questions

- 火山豆包 LLM JSON Mode 是否对所有模型版本（doubao-pro / lite）都支持原生：需要在烟测验证；不支持时 fallback 到文本约束（json_parser 已能处理）
- ASR partial 推送频率（火山官方默认 ~250ms 一次）是否够 800ms 打断阈值的双条件判定：理论上够，烟测验证
- TTS voice_id 命名空间（火山官方音色 ID 形如 `BV001` / `BV002`）：voice_model 表存的是 vendor-specific id；本 change 直接透传，voice_model 增列保留 voice_vendor 字段留 v2
- LLM provider 热切换（运营时切 OpenAI ↔ 火山）：v1 通过重启服务 + env；v2 候选 Campaign 级独立配置
- 连续打断保护策略 `listen_only` 的"您请说"话术是否需要 campaign 配置：本 change 内置常量；运营反馈再加 `campaign.short_reply_listen_only_phrase`
- 火山豆包 LLM 的 finish_reason 映射（vendor "stop" / "length" / "content_filter"）→ ABC 的 FinishReason 字面量保持兼容；非已知值 → "stop" 兜底
- token budget 触发后是否要主动挂断：本 change 仅 WARN，不挂断；运营观察后 v2 决策
- 真 LLM 输出可能超长（>1000 字）触发 TTS 时延：是否需要切分 paragraph 并行 TTS？v1 不切分（一次 stream），观察实际数据后 v2 优化
