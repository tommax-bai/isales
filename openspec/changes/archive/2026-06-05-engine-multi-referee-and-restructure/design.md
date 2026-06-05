## Context

`pipeline-stream-and-referee`（active）已落地的现状（ground-truth 自 isales-engine / isales-common 实码）：

- **单 referee spawn**：`orchestrator.py:93-108` 在 PROCESSING 入口 `asyncio.create_task(run_referee(...))` 起**一个** referee，输出 `RefereeResult{decision, goal_type, confidence, duration_ms}`（`streaming/types.py:8,19-44`），decision 枚举 `continue|goal_achieved|customer_decline|transfer`。
- **决策驱动状态机**：`run_loop.py:701-730`，main TTS 播完后 `_await_referee()`（`run_loop.py:1120-1140`，fail-open 到 `continue`），按 decision 做 `transition_to(WRAPPING_UP/TRANSFERRING/...)`。
- **配置装配**：`runtime_config.py:137-171` 用 `_first(RoleKind.REFEREE)` 取**单行** referee role_config 装进 `PipelineConfig.referee`。`role_config` 表（`isales-common/models/role_config.py`）有 `kind String(16)` + `model` + `temperature/top_p` + **`ext_params JSONB`** + `enabled`，无 name/label 列。
- **campaign 配置**：列 + JSONB 混合（`silence_threshold_ms` 是列、`default_replies`/`silence_phrases`/`interruption_whitelist` 是 JSONB 列）。
- **pipeline_trace**：`run_loop.py:615-639` 写 `referee_decision/referee_goal_type/referee_confidence/referee_duration_ms` 单值。
- **barge-in**：`_partial_monitor()`（`run_loop.py:1204-1276`）置 `interruption_signaled`，`interruption` 事件记 `user_text_at_interruption`（用户的 partial）。**AI 侧残留未说内容在 `_play_streaming` finally `sentences.aclose()`（`run_loop.py:1051-1053`）被直接丢弃，无任何持久化**。
- **会话状态**：`CallSession`（`call_session.py:66-159`）持有 `dialog_history` / `interruption_signaled` / `consecutive_interruption_count` 等运行时字段。

本 change 在此之上做两件正交的事：把单 referee 升级为多 referee + 规则路由；新增 restructure 旁支流。voxen（`~/codes/voxen-main`）的 `multi_stream_router.go` + `llm_dialogue.go:83-95` 是实证参照。

## Goals / Non-Goals

**Goals:**

- referee 从「1 个 prompt 扛多职责」拆为「N 个单职责裁判并行」，每个独立 prompt + 独立输出枚举语义。
- 引入显式、有序、可配置的「路由规则表」：referee 输出 → 匹配 → 动作（状态转移 / 切流）；第一个命中即生效。
- 新增 restructure 流：在「用户没接住 / barge-in 打断 / 主裁判低置信」三场景下，把上一句要点或被打断残留**口语化重说一遍**，而非生成新回复、丢弃、或静默。
- **严格向后兼容**：单 referee + 一组内置默认规则 = 现状行为，已有 campaign 不破。

**Non-Goals:**

- 不引入 voxen 的 tool 路由（transfer_human / sip_hangup 作为 router tool）——iSales 转人工/挂断已由状态机 + `_perform_handoff` 承担，本 change 只把它们表达为规则 action，不另起 tool 子系统。
- 不做多条并行 main dialog stream（voxen 支持多 dialog stream 按规则选）——iSales 主对话仍是单 main + 单 restructure 两条流，规则只在「主流 vs 重组流 vs 状态转移」间选。
- 不改 extractor / worker post-call 抽取链路。
- 不改 main LLM streaming → sentence → TTS 主链路本身。

## Decisions

### D1. 多 referee：role_config.kind=referee 放宽多行 + label 标识

- `role_config` 每 campaign 允许 N 行 `kind=referee`（去掉 `pipeline-stream-and-referee` 的「恰好一行」约束）。
- 每个 referee 需要一个**稳定标识**供路由规则引用。现有表无 name 列。**决定**：新增 `role_config.label String(64) NULL`（仅 referee/restructure 用，main/extractor 留空）。规则按 `label` 绑定 referee，而非按 `role_config.id`（id 在 re-seed 后会变，label 由 campaign 创建者命名、跨 re-seed 稳定）。
  - *备选*：把 label 塞进 `ext_params JSONB`。**否决**：label 要被规则频繁引用 + 唯一性约束（同 campaign 内 referee label 唯一），用正式列比 JSONB 键更清晰、可加 unique index。
- 每个 referee 的「输出枚举语义」写在它自己的 prompt 里（role-prompt spec 规范），engine 不硬编码任何 referee 的枚举值——engine 只拿到 referee 返回的 raw 分类字符串，交给规则引擎匹配。
- *备选*：保留单 referee、把多职责塞进一个 prompt 输出多字段。**否决**：正是现状痛点（耦合、扩不出维度、改一维动全 prompt）。

### D2. referee 输出契约：从「强语义 decision 枚举」松绑为「label + raw category」

- 现状 referee 输出 `{decision, goal_type, confidence}`，`decision` 是 engine 认识的强语义枚举。多裁判下每个裁判的输出语义各不相同（一个吐 `POSITIVE/NEGATIVE`、一个吐 `REJECT/OPERATOR/NEUTRAL`），engine 不该认识它们。
- **决定**：每个 referee 输出 `{category: str, confidence: float}`（去掉 engine 侧 goal_type 语义）。`category` 是该 referee prompt 自定义的分类字符串。engine 把 `{label: category}` 喂给规则引擎；**goal_type 的产出移到规则 action 里**（见 D3：goal_achieved action 自带 goal_type 参数）。
- fail-open 不变：单个 referee 超时/非法/低置信 → 该 referee 视为「无 category 输出」，不命中任何规则（等价于现状的 `continue`）。

### D3. 路由规则表：campaign 维度的有序规则列表，存 JSONB 列

- **承载**：`campaign.routing_rules JSONB`（有序 list）。每条规则：
  ```json
  {"referee": "<label>", "match": ["NEGATIVE"], "action": {...}}
  ```
  `action` 形态：
  - `{"type": "transition", "to": "goal_achieved", "goal_type": "appointment"}` — 状态转移（goal_type 在此带）
  - `{"type": "transition", "to": "transfer"}` / `"customer_decline"`
  - `{"type": "restructure", "source": "last_reply" | "interrupt_remaining"}` — 切重组流
  - （`continue` 不需显式规则——无命中即 continue）
- **匹配**：decider 按 list 顺序遍历，对每条规则取对应 label 的 referee category，命中 `match` 即执行 action 并停止（第一个命中即生效，与 voxen 一致）。
- *备选*：新建 `routing_rule` 表（FK 到 campaign + referee role_config）。**否决（v1）**：规则是「整组一起读、一起改、有序」的配置，不需要单行查询/JOIN；JSONB 列与现有 campaign 配置模式（`default_replies` 等同为 JSONB 列）一致，省一张表 + 一套 CRUD。FK 完整性由 api 层校验 label 存在性替代。**触发换表的条件**（写进注释）：当出现「跨 campaign 复用规则模板」或「规则需被独立查询/审计」需求时迁到正式表。
- **内置默认规则**：migration 给每个现有 campaign 的单 referee seed 一组等价默认规则（`goal_achieved→WRAPPING_UP` / `transfer→TRANSFERRING` / `customer_decline→...`），保证行为等价。

### D4. restructure 流：kind=restructure 单行 role_config + InterruptText 输入

- 新增 `RoleKind.RESTRUCTURE = "restructure"`，每 campaign ≤ 1 行（类比 main，单条重组流足够；voxen 也是单 `restructure_stream`）。
- 装配：`runtime_config.py` 加 `_restructure_spec(_first(RoleKind.RESTRUCTURE))` 进 `PipelineConfig.restructure`（None 时禁用重组，规则里的 restructure action 退化为 continue）。
- 执行：复用 main 的 streaming → sentence → TTS 管线，但**输入构造不同**——不带 dialog_history、不带用户最新一句，只喂 `{system: restructure_prompt, user: InterruptText}`（对齐 voxen `llm_dialogue.go:83-95`）。
- restructure 跑完**不再过 referee**（它本身就是某条规则 action 的产物，再判一轮无意义且增加延迟），直接回 LISTENING。

### D5. InterruptText 的三个来源 = 三个触发场景

在 `CallSession`（`call_session.py` 打断字段区，~135 行后）新增：

```python
interrupt_remaining_text: str | None = None   # (b) barge-in 时 main 残留未说出的句子
last_reply_keypoint: str | None = None        # (a)(c) 上一轮 AI 回复（已存在 dialog_history 末尾，可派生）
```

- **(a) 用户没接住**：某 referee category 命中 `restructure source=last_reply` → InterruptText = `last_reply_keypoint`（取 dialog_history 最后一条 assistant utterance）。
- **(b) barge-in 重说**：**需新增捕获逻辑**——当前 `_play_streaming` finally `sentences.aclose()`（`run_loop.py:1051-1053`）丢弃残留；改为在 `interruption_signaled` 触发的丢弃路径里，把**尚未送进 TTS 的 sentence buffer 文本**拼接存入 `interrupt_remaining_text`，下一轮规则 `restructure source=interrupt_remaining` 命中时作为 InterruptText。捕获后用即清空。
- **(c) 低置信兜底**：主裁判（约定 label=`main_judge` 或规则显式指定的那个 referee）`confidence < 阈值` 时，规则引擎走一条内置「低置信 → restructure source=last_reply」规则，口语化复述上一句拖一轮。**替代** `pipeline-stream-and-referee` 现状的「低置信 → 静默 continue」。

### D6. 「多层兜底是问题味道」合规论证（CLAUDE.md 硬约束）

三类「这一轮不生成新内容」的处置必须职责正交、各有移除条件，不与现有 fail-open / filler / main-异常-默认回复叠层：

| 机制 | 触发条件 | 行为 | 移除条件 |
|---|---|---|---|
| **filler**（现存，默认关） | main LLM 出首句**慢** | 播无意义垫词（"嗯…让我看下"）撑节奏 | streaming 首音频稳定 < 500ms 后永久删 |
| **main 异常默认回复**（现存） | main LLM **报错/流式崩** | 播 campaign `default_replies` 兜底句 | main provider streaming 稳定后评估删 |
| **referee fail-open**（现存） | referee **超时/非法/低置信** | 默认 continue，不误触发状态转移 | referee 协议稳定性达标后收紧 |
| **restructure（本 change 新增）** | main **正常**，但 turn 结果应「重说上一句」（没接住/被打断/拿不准） | 口语化**重组上一句/残留**后说出 | 它不是兜底层而是**正常 turn 的一种 outcome**——无移除条件，是产品行为 |

关键区分：filler/默认回复/fail-open 都在「main 这一轮没正常产出」时补救；restructure 在「main 本可正常产出、但**对话策略**决定应重说而非新说」时生效——是策略分支，不是失败补救。低置信场景 (c) 是唯一交叠点：它把现状「fail-open 静默 continue」替换为「restructure 复述」，是**替换不是叠加**（删掉静默 continue 的低置信分支，换成走规则）。

### D7. engine 执行序（PROCESSING）

1. PROCESSING 入口：`asyncio.gather(*[run_referee(r) for r in referees])` 并行起 N 裁判（替换 orchestrator 单 create_task）。
2. main streaming → sentence → TTS（不变）。main 播完。
3. `await` 所有 referee（带总超时；个别 fail-open）。
4. decider：按 `routing_rules` 顺序匹配 referee categories，得 action（无命中 = continue）。
5. 执行 action：
   - transition → `sm.transition_to(...)`（现状逻辑）。
   - restructure → 构造 InterruptText → 跑 restructure stream → 回 LISTENING。
   - continue → 回 LISTENING。
6. 写 pipeline_trace（多 referee 结果 + matched_rule + restructure_trigger）。

## Risks / Trade-offs

- **[规则配置错误导致死循环/误转移]** → restructure action 跑完强制回 LISTENING 不再过 referee（D4），天然防 restructure 自循环；规则引擎单轮只执行一个 action（first-match-wins），无递归。api 层校验规则引用的 label 存在、action.to 是合法状态。
- **[多 referee 增加每轮 LLM 调用数 → 成本/并发压力]** → referee 用便宜小模型且与 main 并行（不加尾延迟）；N 由 campaign 配置控制，默认仍 1 个。pipeline_trace 记每个 referee duration 供成本观测。
- **[barge-in 残留捕获改动触及最敏感的打断路径]** → 捕获逻辑只在 `interruption_signaled` 丢弃分支**追加**写 `interrupt_remaining_text`，不改丢弃本身的时序/取消语义；restructure 是否真用该残留由下一轮规则决定，捕获失败（残留为空）则 restructure 退化为复述 last_reply。
- **[JSONB 规则无 FK 完整性]** → 接受（D3）；api 层校验 + migration seed 默认规则兜住。换表条件已写进 D3 注释。
- **[与 pipeline-stream-and-referee 同时 active，delta 互覆盖]** → Migration Plan 强约束实施顺序。

## Migration Plan

1. **前置**：`pipeline-stream-and-referee` 跑完剩余 task → `openspec validate pipeline-stream-and-referee --strict` → archive（specs/ 合并）。**本 change 的 spec delta 基于合并后的 specs/ 编写**，否则 referee 段 delta 找不到 base。
2. **isales-common**：加 `RoleKind.RESTRUCTURE`；`role_config` 加 `label` 列 + referee 唯一性约束放宽；`campaign` 加 `routing_rules JSONB` + `restructure` 相关无；`pipeline_trace` 字段重构（多 referee + restructure）；`call_record.prompt_versions` schema 改。一支 alembic migration：DDL + **data migration**（给每个现有 campaign：①给其单 referee 行补 `label="main_judge"`；②seed 等价默认 `routing_rules`）。
3. **isales-engine**：runtime_config 多 referee 装配 + restructure spec；orchestrator gather N referee；run_loop decider 规则引擎 + restructure 执行分支 + InterruptText 捕获；pipeline_trace 写多 referee。
4. **isales-api**：referee CRUD 去唯一约束 + label 字段 + routing_rules 校验 endpoint + restructure role 配置。
5. **isales-web**：多流路由配置页。
6. **回滚**：alembic downgrade 删 restructure 行 + routing_rules 列 + 还原 pipeline_trace 字段；engine 回退到单 referee 装配。因向后兼容设计（单 referee + 默认规则 = 现状），灰度时可先只配 1 referee 验证等价，再逐步加裁判 + restructure。

## Open Questions

- **主裁判 label 约定**：低置信兜底 (c) 需要知道「哪个 referee 是主裁判」。约定固定 label（如 `main_judge`）还是 campaign 显式标记某 referee 为 primary？倾向后者（campaign 配置一个 `primary_referee_label`），apply 时定。
- **restructure 连续触发上限**：用户连续没接住时 restructure 会不会连说几轮「换个说法」显得复读？是否复用现有 `max_continuous_interruptions` / `consecutive_interruption_count` 的同类计数封顶 → 超限走 default_replies 或转人工。倾向加 `max_continuous_restructure` 封顶，apply 时定默认值（建议 2）。
- **category 匹配是否支持模糊**：`match` 目前是精确 `in` 列表。是否需要通配/正则？v1 倾向只精确匹配，prompt 约束 referee 输出闭集枚举。
