# Design — engine-gate-supervision-rename

## Context

三轮代码级 ground-truth（数据模型 / 引擎运行时 / web / spec）确认了三件事，本 change 据此收口：

1. **referee 是 gate-first 主路径门控**，不是旁路。`run_loop._run_gated_turn`：main 回复 eager 生成进 buffer 但不放音 → `await _await_referees`（GATE）→ `decide()` → `_select_gated_route` → 才 `_play_streaming → telephony.audio_out`。门严格在唯一 audio_out 之前。referee LLM 与 main 并行执行（`asyncio.create_task` per referee），所以延迟 p50 ~0ms，且 fail-open（超时不阻塞）——这是「旁路」名字的唯一合理来源（并行执行 + fail-open），但它**描述的是执行模型，不是控制流位置**。

2. **职责是分层的**：门控监管 LLM 只 `emit` 一个 category（`referee.py` 解析裸 token，`confidence` 钉死 1.0）；`decide()`（`pipeline/decider.py`，纯函数）walk `routing_rules` first-match-wins 产出唯一 `DeciderAction`；`run_loop` 执行副作用（放行 / 路由到 persona / restructure / tool）。LLM 对「触发哪个工具 / 是否触发」零 agency。

3. **输出契约有三代并存**：最老 = 单 referee JSON `{decision, goal_type, confidence}`；中间 = 多 referee JSON `{category, confidence}`；现行（engine 已上线）= **裸 category token**（无 JSON、无 confidence、`json_mode=False`）。seed prompt 停在最老一代，导致 live fail-open bug。

## Decisions

### D1 — 代码标识符保留，只改 display / 注释 / spec 叙述

`referee` 作为 `RoleKind` / `kind` 值 / `scope_type` / `HangupCause.REFEREE_HANGUP` / DB 列 / JSON key / 类名 / 文件名**全部保留**。
**Why**：改这些是 isales-common 版本 bump + alembic 枚举迁移 + 6 个消费方 pin 同步 + 全栈部署序，风险与工作量大一档，而功能收益为零（纯术语）。用户的 rename 诉求是面向客户的中文 display（旁路监管 → 门控监管），这只活在 web UI 文案与文档里。
**移除 trigger**：若未来确需把代码标识符也改成 `gate_supervisor`，单开一个 `engine-rolekind-rename` change，含 common enum + alembic + 全栈部署序，不混进本 change。

### D2 — spec 需求标题保留，只改正文 + scenario（避免 RENAMED 复杂度）

spec 的 `### Requirement:` 标题（如「referee LLM 二级决策」「referee 输出契约」）**保留英文 referee 字样**，只在正文 prose + scenario 里做 旁路→门控、side-band→gating、契约修正。
**Why**：spec 标题是工程内部锚点（admin 不读），不是 user-facing display；改标题要走 `## RENAMED Requirements` FROM/TO，增加 validate 风险且让 2 个 colliding change 的归并更难。用 `## MODIFIED Requirements`（按未改的标题匹配替换）最稳。

### D3 — 方向 A：fail-open-to-release，工具触发 best-effort

门控超时 / 全部门控监管失败 → **一律 release**（`referee_fail_open_route`，默认 main），**永不 fail-closed / hold**，**即使该轮本应命中 hangup / transfer**。
**Why（用户拍板 A）**：门控首要职责是低延迟音频放行，fail-open 保证「门控监管抽风也不冻通话 / 不丢回复」。代价是：本该挂断（辱骂）/ 转人工（明确要求）的关键轮，若门控监管恰好超时，工具被静默跳过、音频照常放行。
**接受该代价的依据**：(a) hangup/transfer 仍有非门控的兜底触发路径（inline 关键词/轮次 `evaluate_transfer_cheap`、并行 `evaluate_transfer_llm`、silence/no-progress/operator），关键动作不是只有门控这一条命；(b) 下一轮门控会再判，单轮 miss 不是永久 miss；(c) 方向 B（对 consequential tool 单独 fail-closed / 独立 deadline）会破坏「超时一律放行」的统一性并新增一层逻辑，违背简洁目标。
**显式记录**：本决定使「工具触发」成为 best-effort 而非 guaranteed。若业务后续把「辱骂必挂 / 要求转人工必转」列为合规硬指标，再单开 change 走方向 B 的「独立 deadline」变体（不引入新 fallback 层，只给 consequential category 一个单独超时）。

### D4 — 门控监管 = 纯分类器，契约统一为裸 token

门控监管 prompt MUST 只输出闭集枚举里的**一个 category 词**（无 JSON、无 confidence、无 pass/hold/放行 决策动词）。`confidence` 由引擎钉死 1.0，故删 `CONFIDENCE_THRESHOLD` confidence-floor 死代码。category 闭集**完全来自各 campaign prompt**，引擎 MUST NOT 硬编码（删 `_USER_PRIMER` 的 pass/hold）。
**Why**：这是 ④ 的实现，也是修 live bug 的必要条件。把「放行/选路」职责彻底归给确定性 decider，消除两轮前用户遇到的「referee 既判 pass/hold 又触发工具」的概念双计。
**保留的兜底默认**：删 pass/hold 不等于删「什么都不做就放行」——「无规则命中 → 默认 release(main)」这个 no-match 默认出口**必须保留**（否则正常轮次没东西可放）。删的是 pass/hold 这套词汇，不是删默认放行。

### D5 — 多门控冲突由规则顺序消解（保留）

多个门控监管同轮返回不同 category 时，由 `routing_rules` 的 first-match-wins **顺序**消解（不是谁先返回谁赢）。本 change 不改这个机制，只在 spec 里把它显式写清。

## Risks / Tradeoffs

- **修 seed bug 后门控首次真正生效**：此前 seed campaign 每轮静默放行（门控空转），修后门控会按规则触发挂断/转人工/重组。**部署后 MUST 真机抽验**，确认规则配置符合预期（否则可能出现「修对了反而开始按规则挂断」的体感突变）。这是行为可见变更，不是纯文档。
- **rename 触点多（~40 处）**：机械但量大，靠 `grep` 收尾 + `make test-all` 兜底；代码标识符保留降低了回归面。
- **2 个 colliding change**：archive 顺序敏感，已在 proposal 标注协调点。
- **方向 A 的已知缺口**：工具触发 best-effort（见 D3），显式接受、留 trigger。
