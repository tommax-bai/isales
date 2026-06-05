## Why

当前 iSales pipeline 是 **N-role PK + N×M judges + polish** 三层串联架构，单轮 "用户停说话 → AI 回复首音频" 端到端 **6.5-9.5 秒**（每层等所有候选完整 + JSON 输出 + 等 filler 播完 + 等 pipeline 全完才开 TTS），用户体感延迟严重，跟 voxen 这类同类产品 **0.5-1.5 秒** 量级差 5-8 倍。

根因是**架构性的**（不是参数调优能补的）：三层 PK + judge + polish 每一处都需要"等所有候选完整 → 对比 → 选最佳 → 润色"才能 ship，跟"第一句出来就喂 TTS"的 streaming 哲学根本互斥。voxen 用的是双 LLM 模型——主链路纯文本 streaming 直喂 TTS，结构化决策由 referee 二级 LLM 旁路补足，客户信息提取放到通话结束后离线抽取。

## What Changes

### 架构 pivot（BREAKING）

- **BREAKING** 砍掉 pipeline 三层架构：删除 `_call_roles_parallel` (N-role PK)、`_run_judges_parallel` (N×M judges)、`_call_polish` (polish LLM)。`orchestrator.run_pipeline()` 重写为单 main LLM 流式驱动。
- **BREAKING** main LLM 输出格式：JSON `{reply, goal_achieved, goal_type, extracted}` 改为**纯文本 reply**。prompt template 同步重写。
- **新增** referee LLM（旁路决策）：跟 main LLM 同时启动，输入"用户最后一句 + 最近 3 轮 dialog_history"，输出枚举 JSON `{decision: continue|goal_achieved|customer_decline|transfer, goal_type: appointment|sale|...|null}`。referee 用小模型（如 qwen-turbo / gpt-4o-mini），延迟 ~300ms，与 TTS 播放并行，不阻塞主链路。
- **新增** post-call extractor（worker 服务异步任务）：通话结束后从 transcript 抽取 `extracted: {customer_name, intent, callback_time, ...}` 字段写入 `call_record.extracted`，由 worker 服务的新 consumer 处理 Redis Queue `isales:extract`。

### 数据契约改动（BREAKING）

- **BREAKING** `role_config.kind` 枚举：从 `{role, judge, polish}` 改为 `{main, referee, extractor}`。alembic migration 删除现有 judge/polish 行（campaign 配置需重建 main/referee/extractor 三行）。
- **BREAKING** `pipeline_trace` 表：删除 `role_candidates`（list 改 single）/`judge_results`/`polish_input`/`polish_output`/`polish_duration_ms`/`polish_role_config_id`/`polish_prompt_version_id`/`final_selected_candidate_index` 字段；新增 `main_reply_text`/`main_duration_ms`/`referee_decision`/`referee_goal_type`/`referee_duration_ms`/`first_audio_ms`（首音频延迟监控）字段。
- **BREAKING** `call_record.prompt_versions` JSONB schema：`{role_llms[], judge_llms[], polish_llm}` 改为 `{main_llm, referee_llm, extractor_llm}`。
- `call_record.extracted` 字段：从"engine inline 实时写"改为"worker post-call 异步写"，schema 不变。

### Provider 层

- **新增** `LLMProvider.chat_stream(...) -> AsyncIterator[str]` 抽象方法。Volcengine / Ark / OpenAI-compatible / DashScope 4 个实装同步加 streaming 支持（SSE `stream=true`）。原 `chat(...) -> LLMResponse` 保留供 referee / extractor 用。
- TTS provider **不变**（已经是 SSE streaming，但 caller 改为真正消费 stream）。

### Engine 层

- `run_loop._main_turn_loop` 的 PROCESSING → SPEAKING 路径改造为流式：main LLM token → sentence boundary detector → TTS chunk-fed → playback。每个 sentence 完一句就推一句给 TTS，不等 LLM 全部完成。
- FILLER 行为：保留概念但默认关掉（streaming 主链路 ~500ms 首音频，filler 反而拖累）。campaign 可显式启用，但 `await filler.wait_finished()` 阻塞 gate 删除（filler 与回复 TTS overlap，回复 TTS 一就绪立即 preempt filler 音频通道）。
- referee task 在 PROCESSING 入口与 main LLM 并行 spawn；其结果在 SPEAKING 状态结束前 await，驱动下一轮 state transition（goal_achieved → WRAPPING_UP / transfer → TRANSFERRING / customer_decline → ACTIVATING 或 END）。

### Worker 层（新增 consumer）

- `isales-worker` 新增 `post_call_extractor` consumer：BLPOP `isales:extract` 队列，输入 `{call_record_id, transcript_snapshot, extractor_role_config_id, extractor_prompt_version_id}`，调 LLM provider 跑结构化提取，结果 UPDATE `call_record.extracted`。
- engine 在 END 状态前 LPUSH 该队列（在原 call_summary_writer 同流程内）。

### Web admin（BREAKING）

- **BREAKING** 删除 judge / polish prompt 编辑页 + RoleConfig 列表的 judge / polish 行。
- 新增 referee / extractor 配置入口（model + prompt_version 选择）。
- main role prompt 编辑器移除 JSON 输出强制提示，改为"纯文本回复"指引。

### 历史 change housekeeping

- 5/29 archive `engine-judge-dialog-context` 标 SUPERSEDED-by-pipeline-stream-and-referee（chat-history-into-judge 整段逻辑被推翻）。
- 5/8 archive `impl-web-polish` 标 SUPERSEDED-by-pipeline-stream-and-referee（polish UI 整段删除）。
- 5/29 archive `engine-judge-dialog-context` 提到的 chat-history 拼装思路**继承到 referee**（referee 也用最近 3 轮 dialog_history 作为输入），不浪费已有设计。

## Capabilities

### New Capabilities

无。referee / post-call extractor 属于 `ai-pipeline` capability 的内部成分；worker queue 走现有 `service-communication` 通道契约。

### Modified Capabilities

- `ai-pipeline`: § 三层管线整段删除，新增 § "单 main LLM streaming"、§ "referee 二级决策"、§ "post-call extractor 异步抽取" 三段。pipeline_trace schema 同步修改。
- `role-prompt`: 删除 § "judge prompt 组装"、§ "polish prompt 组装"、§ "judge 收到 dialog_history" 三段。修改 § "main role prompt" 段：移除 JSON Mode 强制，改为纯文本输出 + system prompt 加约束"不要输出 markdown / emoji / JSON"。新增 § "referee prompt"、§ "extractor prompt" 两段。
- `data-model`: § "role_config.kind 枚举" 改 `{main, referee, extractor}`；§ "pipeline_trace 字段" 重写（删 judge/polish 相关，加 referee / first_audio_ms）；§ "call_record.prompt_versions JSONB" schema 改。
- `provider-abc`: 新增 § "LLMProvider.chat_stream 流式接口"。
- `goal-achievement`: § "goal_achieved 触发来源" 修改：从 "polish LLM JSON 字段" 改为 "referee LLM decision 枚举"。状态机转移逻辑（goal_achieved → WRAPPING_UP）保持不变。
- `transcript`: § "pipeline_trace_records 字段" 重写（与 data-model 同步）；ai_reply 事件保留，event payload 不变（`text` 字段从"polish 输出"改为"main streaming 输出聚合"，对消费方透明）。
- `web-admin-ui`: § "RoleConfig 编辑页" 改：删 judge / polish 编辑入口，加 referee / extractor 入口；§ "Campaign 配置页" 改：main / referee / extractor 三段 role 选择。
- `service-communication`: § "Redis Queue 矩阵" 新增 `isales:extract` 队列条目（engine LPUSH → worker BLPOP）。

## Impact

**受影响 sub-repo**：
- `isales-engine`: orchestrator 整体重写 / run_loop PROCESSING 路径流式重构 / 新增 referee 模块 / LLM provider 加 chat_stream 实装 / FILLER manager 去阻塞 gate
- `isales-common`: PipelineConfig / RoleSpec / RefereeSpec / ExtractorSpec 数据类 / pipeline_trace 模型 / role_config.kind 枚举 / call_record.prompt_versions schema / 新增 alembic migration
- `isales-worker`: 新增 post_call_extractor consumer + Redis Queue 订阅
- `isales-web`: campaign + role_config 编辑页删 judge/polish 加 referee/extractor / main role prompt 编辑器去 JSON 强制
- `isales-api`: campaign 配置 API schema 改 / role_config 列表 API 过滤 kind 枚举
- `isales-scheduler`: 影响极小（只看 campaign 是否 ready，不关心 role_config 细节）
- `isales-telephony`: 完全不动

**数据库 migration**：
- alembic 新版本：role_config.kind 枚举改 + 删除 judge/polish 行 + pipeline_trace 字段重构。**风险**：现有 campaign 的 judge / polish 配置数据丢失。由于 v1 还没真实生产数据，acceptable；但需要在 RUNBOOK 写明"运行 migration 前先备份 + migration 后需要重建 campaign 的 main/referee/extractor 三行"。

**部署顺序**（强约束）：
1. isales-common 先发布（alembic migration + 新 dataclass）
2. isales-engine 升级（pin 新 common 版本）
3. isales-worker 升级（pin 新 common 版本 + 新 consumer 启动）
4. isales-api + isales-web 升级（UI / API 配套）
5. campaign 配置数据重建（手工或 seed 脚本）

**性能预期**：
- 首音频延迟从 ~6500-9500ms 降到 ~500-1500ms（5-8x 提升）
- main LLM provider 调用从 N 个并行降到 1 个（成本下降 ~70% on LLM token cost，因为 judge / polish round-trip 全砍）
- referee 增加 1 个小模型 round-trip，token 成本极低（输入只是 1 句 + 3 轮 history）
- extractor 转离线，平均时延无所谓，可用便宜模型

**风险**：
- main LLM 单点失败（原 N-role PK 有冗余）→ provider 层 retry + chat() fallback 保留
- 单 prompt 调优替代 N-role + polish 的质量保证 → 必须先用 mac dev 跑足够样本验证 prompt 质量 ≥ 现状（main prompt 设计 + system prompt 约束是本 change 的隐性大头）
- referee 延迟极端情况 > main TTS 播完 → state transition 卡顿，但 main TTS 已经播完了不影响用户听感；若 referee 持续超时，下一轮 LISTENING 默认继续对话（fail-open）

**Followup（不在本 change scope）**：
- TTS provider Linux 端 binary 支持（DingRTC SDK 已 cover），无新动作
- FILLER manager 长期是否完全删除？本 change 默认关但保留代码，followup 若 3 个月内无 campaign 启用则删
- ASR `_PARTIAL_STABLE_S=0.7` 是否减到 0.3？本 change 不动，followup change `asr-fast-eos` 单独评估
- 多 campaign A/B 工具 / 灰度发布机制 → followup `campaign-feature-gating`
