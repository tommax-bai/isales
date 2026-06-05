## Context

iSales engine 当前 pipeline 是 **N-role PK + N×M judges + polish** 三层架构（详见 archive 的 `2026-05-07-impl-engine` / `2026-05-08-impl-engine-providers` / `2026-05-29-engine-judge-dialog-context`）。设计假设是"多 role 横向对比 + judge 打分过滤 + polish 选最佳并润色"，质量靠对比性保证。

2026-06-02 ~ 2026-06-03 mac dev-no-modem 真 mic 测试 + ECS engine 部署后，用户报告**通话延迟感很强**。本对话上半段对照 voxen（同类产品 Go 实现）做了端到端时间分解：iSales 首音频 **6.5-9.5s**，voxen **0.5-1.5s**，差 5-8 倍。瓶颈是结构性的：

1. ASR `_PARTIAL_STABLE_S=0.7s` 硬等（贡献 ~700ms，不在本 change scope，followup `asr-fast-eos`）
2. Pipeline 三层串联 + 层间等所有候选完整（贡献 ~5s，**本 change 主要目标**）
3. `await filler.wait_finished()` gate（贡献 ~500-2000ms，**本 change 顺带处理**）
4. TTS 整体等 stream 完才 play（贡献 ~1-2s，**本 change 顺带处理**）

voxen 的低延迟靠**双 LLM 架构**：主链路纯文本 streaming 直喂 TTS（`llm_dialogue.go:97-140` 单纯 token 转发），结构化决策（hangup / transfer）由旁路 referee LLM 二级路由补足（`voiceConfig.example.json:83-109` 两级 LLM 拆分），客户信息抽取它根本没做（voxen 是通用 AI agent，无销售 CRM 场景）。

本 design 把 voxen 模式适配到 iSales 销售外呼场景：保留"goal_achieved 触发 WRAPPING_UP / transfer / customer_decline 状态机转移"和"extracted 客户信息入库"两个销售特有需求，但分别用 inline referee 和 post-call extractor 解决，**不让它们阻塞主 streaming 链路**。

## Goals / Non-Goals

**Goals:**

- 首音频延迟从 ~6500-9500ms 降到 ~500-1500ms（5-8x 提升），达到 voxen 量级
- 保留 `goal_achieved` inline 触发 `WRAPPING_UP` 状态机转移的实时性（销售场景关键：客户答应"周三上午方便"立刻收尾，不能等通话结束才知道）
- 保留 `extracted` 客户信息入库（但可以异步）
- 保留 `transfer` 决策的 inline 触发（销售场景关键：客户说"我要找人工"立刻转）
- LLM token 成本下降（main 1 个 vs 原 N + N×M + 1）

**Non-Goals:**

- **不**在本 change 内动 ASR `_PARTIAL_STABLE_S` 参数（followup `asr-fast-eos` 单独评估，本 change 只动 pipeline 层）
- **不**做 A/B / 灰度发布机制（彻底切换，campaign 数据手工重建；followup `campaign-feature-gating` 单独做）
- **不**保留 PK / judges / polish 任何 fallback 代码（按 CLAUDE.md `feedback_avoid_multilayer_fallback` 原则）
- **不**做 main LLM 多 provider 同时跑的冗余（用 provider 层 retry + chat() fallback 解决可靠性）
- **不**改 telephony / scheduler / api 业务流程，只改 engine + worker + common 的数据契约 + web 的配置 UI

## Decisions

### 决策 1：main LLM 输出纯文本，prompt 显式约束"不要 JSON / markdown / emoji"

main LLM 输出**纯文本 reply**（不再 JSON Mode），prompt 在 system 段加约束。

```
# main LLM system prompt 末段示例（加在原有销售角色定义之后）：
你的输出必须遵循：
1. 只输出你要对客户说的话，不要任何解释 / 元信息 / 引号包裹
2. 不要使用 markdown 标题 / 加粗 / 列表
3. 不要使用 emoji / 表情符号
4. 不要输出 JSON / 代码块
5. 如果有多句，用句号 / 问号 / 感叹号自然分隔
6. 单句长度控制在 30 字以内（便于 TTS 自然停顿）
```

**Rationale**: 纯文本是 streaming 最自然的格式，无需流式 JSON parser（脆弱）。约束写在 prompt 而非 vendor json_mode，保留 prompt 自然表达。

**Alternatives considered**:
- (A) 保留 JSON + 流式 JSON parser 抓 `"reply": "..."` 字段：流式 JSON 解析对转义字符 / 中文引号脆弱，且 vendor token 边界跨字符切引号会漏字。否决。
- (B) 自定义分段格式 `REPLY: xxx ===END=== {metadata}`：增加 prompt 不自然感，引入新分隔符约定，runtime 还得维护状态机切段。比 A4 复杂无收益。否决。

**Why now**: 选 voxen 同款（也用 prompt 软约束，不强 json_mode），证明在生产可行。

### 决策 2：referee LLM 并行旁路 + 输出枚举 JSON

referee 与 main LLM **同时** spawn（PROCESSING 入口 `asyncio.create_task`），输入 `{user_last_utterance, recent_dialog_history: [...]}`（最近 3 轮 user/assistant 对话），输出严格 JSON。

```json
{
  "decision": "continue" | "goal_achieved" | "customer_decline" | "transfer",
  "goal_type": "appointment" | "sale" | "callback" | null,
  "confidence": 0.0~1.0
}
```

referee 用便宜小模型（推荐 `qwen-turbo` / `gpt-4o-mini`），延迟 ~300ms，**与 main TTS 播放并行**。决策结果在 SPEAKING 状态结束前 await（main TTS 播完时 referee 一般已完成）：

```python
# 伪码
async def _processing_phase(...):
    main_task = asyncio.create_task(_run_main_stream(user_input, ...))
    referee_task = asyncio.create_task(_run_referee(user_input, recent_history, ...))
    
    # main 流式喂 TTS（先返回控制流，async 播放）
    async for sentence in main_task:
        await tts.synthesize_stream_chunk(sentence)
        await rtc.audio_out(...)
    
    sm.transition_to(SPEAKING, ...)  # main 已开始播
    # 等 TTS 播完
    await speaking_done.wait()
    
    # 此时 referee 大概率已完
    referee_result = await asyncio.wait_for(referee_task, timeout=2.0)  # fail-open
    if referee_result.decision == "goal_achieved":
        sm.transition_to(WRAPPING_UP, reason=referee_result.goal_type)
    elif referee_result.decision == "transfer":
        sm.transition_to(TRANSFERRING, reason="referee_decision")
    elif referee_result.decision == "customer_decline":
        sm.transition_to(ACTIVATING, reason="customer_decline_recovery")
    else:  # continue
        sm.transition_to(LISTENING, reason="tts_done")
```

**Rationale**: referee 把"结构化决策"从主 LLM 剥离，主 LLM 不再背 JSON 包袱。referee 输入很短（用户最后一句 + 3 轮 history），输出 enum，token 成本极低；与 main 并行起，不增延迟。

**Alternatives considered**:
- (A) referee 串行在 main 之后跑：增 300ms 等待。否决。
- (B) referee 用与 main 同 model：成本上升。否决。
- (C) 把 referee 决策放到 worker 离线：失去 inline 触发 WRAPPING_UP / TRANSFERRING 实时性，下一轮 user 已经在说话了才知道要收尾。否决。

**fail-open 默认**: referee 超时 / 错误 → 默认 `continue`，继续 LISTENING。这跟 PK + polish 的 `_default_reply_outcome` 是同语义（保通话不挂）。

### 决策 3：post-call extractor 走 worker 服务 + Redis Queue

engine 在 END 状态前 LPUSH `isales:extract` 队列，载荷：

```json
{
  "call_record_id": 12345,
  "transcript_snapshot": [...],  // 完整 dialog_history 序列
  "extractor_role_config_id": 7,
  "extractor_prompt_version_id": 13
}
```

worker 服务新增 `post_call_extractor` consumer：BLPOP 队列 → 调 LLM provider 用 `chat(json_mode=True)` 输出 `{extracted: {...}}` → UPDATE `call_record SET extracted = ...`。

**Rationale**: extractor 不影响 inline 通话流程，可以用便宜模型 + 长 timeout，可以 retry。走 worker 而非 engine 内 asyncio.create_task 是因为 engine 进程在 END 状态后 session 就 tear down 了，没地方 await。Redis Queue 提供持久化（worker 重启不丢）。

**通道选择**: 用 Redis Queue（按 `service-communication` spec 矩阵：必须送达 + 异步 OK = Queue 而非 Pub/Sub）。

**Alternatives considered**:
- (A) engine 同步在 END 前调 LLM 写 extracted：阻塞挂电话流程，用户已经听到再见还在等 extractor，否决。
- (B) worker 跑定时扫描 `call_record WHERE extracted IS NULL`：浪费 DB IO + 不实时，否决。

### 决策 4：FILLER 默认关、阻塞 gate 删除、保留代码作 opt-in

`await filler.wait_finished()` 删除。filler 现在与 main TTS 完全 overlap：

- filler 先启动（PROCESSING 入口），播一段 "嗯…让我看一下"
- main TTS 第一 chunk 到 → 立即 preempt filler（通过 `current_speaking_task.cancel()` 同 5/28 barge-in 路径）
- filler 自然结束 / 被 preempt 都不阻塞主流程

campaign 配置默认 `filler_enabled=False`。原有 filler / FillerManager 代码保留，campaign 显式 opt-in 时按 5/27 路径起。

**Rationale**: streaming 主链路首音频 ~500ms，filler 本质上是"掩盖 thinking latency"的 patch，现在 thinking 已经 ≤ 500ms 不需要掩盖。但保留代码 + opt-in 是为了应对未来"个别 campaign 用慢模型"场景。

**注意**: 这是"保留代码 + opt-in"的 fallback 路径，按 CLAUDE.md `feedback_avoid_multilayer_fallback` 必须标注移除 trigger。**移除 trigger**: 本 change archive 后 3 个月内若无 campaign 启用 `filler_enabled=True`，followup change `pipeline-remove-filler` 删除全部 filler 代码。

### 决策 5：彻底切换 vs campaign 双轨 → 选彻底切换

按 CLAUDE.md `feedback_avoid_multilayer_fallback` + `feedback_release_atomicity`：

- 删除 N-role PK / judges / polish 全部代码 + DB schema 字段
- 删除 web admin judge / polish 编辑页
- 删除 5/29 `engine-judge-dialog-context` 引入的 chat-history-into-judge 代码（archive 标 SUPERSEDED）
- alembic migration 必须删 `role_config.kind IN ('judge', 'polish')` 行

**Rationale**: v1 还没上真实生产，没有"双轨灰度"业务必要；保留双轨会产生永久维护债（两套 orchestrator / 两套 prompt 编辑器 / 两套测试），违反 `feedback_release_atomicity`。

**Risk**: 切换后 streaming 主链路单 prompt 调优替代原 N-role + polish 的对比质量保证，prompt 质量调不好会回归。**Mitigation**: 实施 Phase 5（验证）必须先在 mac dev 跑 ≥ 20 通模拟对话，prompt 输出质量 ≥ 现状再 ECS 部署。

### 决策 6：alembic migration 数据破坏接受

migration 删 `role_config.kind IN ('judge', 'polish')` 行 + 删 `pipeline_trace` 表的 judge_results / polish_* 字段。**campaign 的 judge / polish 配置数据丢失**。

**Rationale**: v1 还没真实生产数据，acceptable。但 RUNBOOK 必须更新：migration 前手工备份 + migration 后需要给 campaign 重建 main/referee/extractor 三行 role_config。

### 决策 7：LLM provider chat_stream 抽象 ABC

`LLMProvider` 新增：

```python
@abstractmethod
async def chat_stream(
    self,
    messages: list[Message],
    *,
    temperature: float = 1.0,
    top_p: float = 1.0,
    max_tokens: int | None = None,
) -> AsyncIterator[str]:
    """Stream content tokens (text chunks) over SSE. Each yielded str is a token / delta."""
    raise NotImplementedError
```

4 个实装（Volcengine / Ark / OpenAI-compatible / DashScope）同步加 SSE `stream=true`。

**Rationale**: 这是新接口（ADDED），不修改现有 `chat()`（referee / extractor 仍用 chat()）。OpenAI-compatible 实装基本拷贝 voxen 的 `chat_model.go:37-50` 模式（移除 response_format / 加 stream=true / 用 SSE 解析 delta.content）。

### 决策 8：sentence boundary detector

main LLM yield 的 token 流需要切句子才能喂 TTS。规则：

- 累积 token 到 buffer
- 命中 `。？！` 或 `\n\n` 或 buffer 超 50 字 → 切一句送 TTS
- 末尾 buffer 在 stream 结束时整体 flush

实装在 engine 的 `streaming/sentence_splitter.py`（新文件）。

**Rationale**: voxen 的 `textproc/processor.go:19-30` 走类似规则。50 字 cap 是为避免单句过长 TTS 一次合成延迟回弹。

## Risks / Trade-offs

- **质量回归**: 单 main prompt 替代 N-role PK + polish 的对比质量保证 → **Mitigation**: 实施前 mac dev 跑 ≥ 20 通模拟对话验质量；prompt 设计纳入本 change 的 task；保留 prompt_version 管理便于回滚 prompt。
- **referee 决策错误**: referee 是小模型，可能把"客户在犹豫"误判为"customer_decline" → **Mitigation**: prompt 加 confidence 字段；engine 层 confidence < 0.7 时 fail-open（默认 continue）。
- **streaming 中断的用户体验**: 主链路任何一段崩（main LLM SSE 断流 / TTS 断流 / RTC 断流）会让 AI 中途没声音 → **Mitigation**: provider 层 retry（chat_stream 加 1 次 reconnect）；engine 层捕获 chat_stream 异常时切回 chat() 一次性兜底（带 5s 时延）。**这是个 fallback，标注移除 trigger**: streaming 链路 30 天 SLA ≥ 99.5% 后 followup 删除一次性兜底。
- **post-call extractor 队列堆积**: 大量通话同时结束 → worker BLPOP 单进程处理不过来 → **Mitigation**: worker 服务的 extractor consumer 可水平扩展（多进程 / 多 worker pod），共享 Redis Queue。
- **prompt_version 数据丢失**: alembic migration 删 judge / polish 历史 prompt_version → **Mitigation**: 部署前手工备份 prompt_version 表；本 change 完成后历史 polish prompt 已无业务用途。
- **5/29 engine-judge-dialog-context 的 chat-history 思路被推翻**: 但其"用 dialog_history 作为 LLM 额外上下文"的设计 idea 继承到 referee（referee 用最近 3 轮 history）+ extractor（extractor 用全 transcript）。不浪费上次 session 的设计成果。

## Migration Plan

**前置准备**（实施前一天）:
1. 备份 ECS `psql -c "COPY (SELECT * FROM role_config) TO ..."` 全表
2. 备份 `prompt_version` 全表
3. 备份 `pipeline_trace` 全表（虽然字段要改，历史数据可读旧字段）

**isales-common 发布**:
1. 写 alembic migration `xxxx_pipeline_stream_and_referee.py`：
   - `ALTER TYPE role_kind RENAME TO role_kind_old` + 创建新 enum `{main, referee, extractor}` + `ALTER COLUMN role_config.kind` 切换 + `DROP TYPE role_kind_old`
   - `DELETE FROM role_config WHERE kind IN ('judge', 'polish')`（用 enum 切换前的 raw text）
   - `ALTER TABLE pipeline_trace DROP COLUMN role_candidates`（改为新字段）/ DROP judge_results / DROP polish_*
   - `ADD COLUMN main_reply_text TEXT / main_duration_ms INT / referee_decision TEXT / referee_goal_type TEXT / referee_duration_ms INT / first_audio_ms INT`
2. Pydantic schema 改：`RoleSpec` 简化、新增 `RefereeSpec` / `ExtractorSpec`、`PipelineConfig` 用新 dataclass
3. bump version → pip publish 私服 / 直接路径 install

**isales-engine 发布**:
1. pip 升级 isales-common
2. 实装 LLMProvider.chat_stream（4 个 vendor）
3. 重写 `pipeline/orchestrator.py` → 主 streaming + referee 旁路
4. 改 `run_loop._main_turn_loop` PROCESSING → SPEAKING 路径
5. 删 `pipeline/_call_roles_parallel` / `_run_judges_parallel` / `_call_polish` / 相关 prompt builder 段
6. 新增 `engine/referee.py` 模块
7. 新增 `streaming/sentence_splitter.py`
8. 删 `await filler.wait_finished()`，FILLER 改 preempt 模式
9. scp 部署 + systemctl restart

**isales-worker 发布**:
1. pip 升级 isales-common
2. 新增 `post_call_extractor.py` consumer
3. systemd unit + restart

**isales-api / isales-web 发布**:
1. role_config 列表 API filter 改新 kind
2. web admin RoleConfig 编辑页：删 judge/polish UI + 加 referee/extractor UI
3. campaign 配置页：main/referee/extractor 三段 role 选择 + filler_enabled toggle

**campaign 配置重建**（手工）:
- 给 dev campaign 1 创建 main + referee + extractor 三个 role_config
- 写好对应 prompt_version

**验证**（强阻断）:
- mac dev-no-modem fake-WAV ≥ 5 通跑通（首音频 < 1.5s + referee inline 触发 WRAPPING_UP + extracted post-call 入库）
- mac dev-no-modem 真 mic ≥ 5 通（同上）
- ECS 部署 + Windows 真拨号 ≥ 10 通

**Rollback**:
- isales-engine git revert + scp 旧 orchestrator.py / run_loop.py + systemctl restart
- isales-common alembic downgrade（恢复 role_kind 旧 enum + pipeline_trace 旧字段）
- isales-worker disable post_call_extractor service
- isales-web rollback build artifacts
- campaign 配置从 migration 前的备份恢复

回滚约束：post-call extractor 已写入的 `call_record.extracted` 数据不丢（schema 不变）。

## Open Questions

- **Q1**: referee 用什么 model？候选：`qwen-turbo`（阿里）/ `gpt-4o-mini`（OpenAI 兼容路）/ `doubao-lite`（字节）。决策点：成本 + 中文意图分类质量。本 change 实施期间 mac dev 跑 ABC 对比，最终选 1 个写进 RUNBOOK。
  → 暂定 `qwen-turbo` 作为 default，campaign 可覆盖。

- **Q2**: extractor 是否也走 streaming（不需要）？extractor 输出 JSON dict，且离线无延迟敏感。**结论**：extractor 用 `chat(json_mode=True)` 而非 chat_stream，简洁。

- **Q3**: 单句长度 50 字 cap 是否合理？过短会拆得太碎 TTS 自然度差，过长会单句 TTS 延迟回弹。
  → 实施时 mac dev 跑实测 30/50/80 字三档对比，选最佳。

- **Q4**: referee 失败重试策略？
  → 暂定不 retry（fail-open continue）。followup `referee-reliability` 评估 retry 收益。

- **Q5**: post-call extractor 失败处理？
  → engine LPUSH 时同时写 `call_record.extract_status='pending'`；extractor 成功 UPDATE `extract_status='done'`，失败 UPDATE `extract_status='failed' + error`。worker 不做无限 retry（防雪崩），ops 通过 SQL 查 `extract_status='failed'` 手工触发重跑。
