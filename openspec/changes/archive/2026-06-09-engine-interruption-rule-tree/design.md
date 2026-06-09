## Context

iSales barge-in 决策实现在 `isales-engine/isales_engine/realtime/interruption_detector.py::evaluate_partial`，由 `run_loop.py::_partial_monitor` 在 SPEAKING / FILLER 状态下对每个 ASR partial 调用。当前是一条**写死的条件序列**：

```
text.strip() in whitelist        → ignored("whitelist")     # 精确匹配
len(text.strip()) < 2 (硬编码)    → ignored("text_too_short") # prototype #136
elapsed_ms < min_duration_ms     → ignored("below_threshold")
else                             → triggered("exceeds")
```

`whitelist` / `min_duration_ms` 来自 PG campaign 列，`min_text_length` 还是 prototype 硬编码（active change `interruption-detection-text-length-gate` 想把它提升成配置，但未 apply）。整套逻辑**不可由客户组合配置**。

参照系是 voxen（`~/codes/voxen-main/core/interruption/`，已对真代码验证）：一棵从 JSON 递归构建的布尔规则树，叶子 `keyword`（子串）/ `length` / `timeInterval` / `regexPattern` / `splitByDelimiter` / `none`，组合 `and` / `or` / `not`，`Rule.should_interrupt(text) -> InterruptionResult`。voxen 的"AI 是否在说话"前置门由它的状态层（`CanCheckASRInterrupt`）单独把守——iSales 的等价物是 `_partial_monitor` 只在 SPEAKING / FILLER 跑，**本 change 不动这个状态门**。

附带处理两笔债：（1）`decider.py` 的 low_confidence 内置兜底因 `referee.py` 把 bare-token referee 的 `confidence` 硬编码成 1.0 而恒不触发，是死分支；（2）`_vad_monitor` 的 VAD-source cancel 经 2026-06-03 真 mic 实测会被 ambient noise 误触发（见被吸收 change 的 design）。

## Goals / Non-Goals

**Goals:**
- 把 `evaluate_partial` 的写死序列**替换**为一棵可组合、可配置的规则树（port voxen），客户能按场景组合 and/or/not + keyword/length/duration/regex/delimiter。
- 规则树存 campaign JSONB（`interruption_rules`），`runtime_config` 装配进 `InterruptionConfig`。
- **缺省零行为变化**：未配规则树的 campaign 走一棵从现有 `interruption_whitelist` + `interruption_min_duration_ms`（+ 字数≥2）合成的默认树，与今天逐字节等价。
- 吸收 `interruption-detection-text-length-gate`：min_text_length 并入 `length` 叶子；`_vad_monitor` 去 cancel 副作用、仅留 corroboration mirror。
- 删 `low_confidence` 死分支（decider + types + trigger label + 文档注释）。

**Non-Goals:**
- **不**动 restructure 取材（`last_reply` / `interrupt_remaining` 语义保留），只删那条永不触发的 low_confidence 触发场景。
- **不**动 `_partial_monitor` / `_asr_pump` / `asr_partials_q` 调用框架，也不动「打断判定不可撤销」「连续打断保护」「与 FILLER/WRAPPING_UP 交互」等既有 Requirement。
- **不**动状态门（"只在 SPEAKING/FILLER 评估打断"）——它已是 voxen `CanCheckASRInterrupt` 的等价物。
- **不**完全删除 `_vad_monitor` task（它仍 mirror `vad_voice_active_ms` 给 corroboration），完全删属 followup。
- web 编辑面**本 change 只定 schema/契约**，UI 实现分阶段。

## Decisions

### D1. 规则树形态：tagged-union 递归，叶子 + 组合，编译一次

port voxen 的结构到 Python：

- `Rule` 协议：`should_interrupt(ctx: RuleInput) -> RuleVerdict`，`ctx = RuleInput(text: str, elapsed_ms: int)`。
- 叶子：`keyword`（命中词集，见 D2）、`length`（`len(text.strip())` rune 数 ≥ `value`）、`duration`（`elapsed_ms ≥ value_ms`，见 D3）、`regex`（`re.search(pattern, text)`）、`split_by_delimiter`（含任一分隔符）、`none`（恒 false = 禁用）。
- 组合：`and`（全真，短路）、`or`（任一真，短路）、`not`（取反）。
- factory：`build_rule(config: dict | None) -> Rule`，`None` / `{"type":"none"}` → NoneRule。

**JSON 形态**（对齐 voxen）：`{"type":"and","rules":[{"type":"length","value":2},{"type":"not","rule":{"type":"keyword","values":["嗯","好的"]}},{"type":"duration","value_ms":800}]}`。

**编译时机**：规则树在 `runtime_config` 装配 `InterruptionConfig` 时**编译一次**成 `Rule` 对象树，`evaluate_partial` 每个 partial 只调 `tree.should_interrupt(...)`，不每次重建（voxen 同样持有单个 Rule 实例）。

**Why over 现状**：写死序列只能表达「whitelist AND length AND duration」一种固定 AND。规则树让客户表达「(关键词A OR 正则B) AND NOT 语气词 AND 时长」之类任意策略，且新增规则类型只加一个叶子类，不改 `evaluate_partial` 主体。

**Alternatives**：(A) 加几个并列配置字段（min_text_length / keyword_mode / regex_list）——仍是写死组合，加一种策略就要改代码，正是要消除的；(B) 直接内嵌 voxen Go 二进制——跨语言、无意义。

### D2. `keyword` 叶子支持 `match: "contains" | "exact"`，默认树用 `exact` 保持等价

voxen `keyword` 是**子串**匹配（`contains`），iSales 现 `whitelist` 是**精确**匹配（`_stripped in whitelist`）。两者对「好啊」行为不同（精确不命中「好」、子串命中）。

**决定**：`keyword` 叶子带 `match` 字段，新配置默认 `"contains"`（voxen 风格，更强的语气词过滤）；但**向后兼容默认树**用 `match:"exact"` 从 legacy `interruption_whitelist` 合成，逐字节复刻今天 `_stripped in whitelist` 的行为。命中前对尾部标点做 trim（对齐 voxen `keyword_rule` 的 `TrimRight`）。

**Why**：既给客户 voxen 的子串能力，又让没配规则树的存量 campaign 行为**零变化**。

### D3. `duration` 叶子用 iSales 语义（自用户 speech_start 计时），**不**照搬 voxen `timeInterval`

voxen `timeInterval` 是「自规则首次评估起 N 秒去抖」，且 voxen 自己从不调 `Reset()`，实际退化成「整通电话只去抖一次」（已对其代码验证，是个半坏语义）。iSales 现 `min_duration_ms` 是「自**用户** speech_start 起 elapsed ≥ N」——每轮用户说话重新计时，语义更清晰且更有用。

**决定**：提供 `duration` 叶子 = iSales 语义（`ctx.elapsed_ms ≥ value_ms`），**不**移植 voxen 那条易混淆的 `timeInterval`。`RuleInput` 因此带 `elapsed_ms`（由 `_partial_monitor` 现已计算的 `now - speech_started`）。

**Why**：移植 voxen 的**可组合性**，但保留 iSales 更正确的去抖锚点；避免引入一条自己都没用对的规则。

### D4. 向后兼容：`interruption_rules` NULL → 运行时从 legacy 列合成默认树（**不**回填）

新列 `campaign.interruption_rules JSONB NULL`。`runtime_config` 装配时：

- 非 NULL → `build_rule(interruption_rules)`。
- NULL → 合成默认树 `AND( NOT keyword(exact, interruption_whitelist), length(value=2), duration(value_ms=interruption_min_duration_ms) )`。

**决定**：**不**做 data migration 把默认树回填进每个 campaign 行——保持 NULL，运行时从 legacy 列（`interruption_whitelist` / `interruption_min_duration_ms`）合成。

**Why over 回填**：回填会让"同一份打断策略"同时存在于 legacy 列和 `interruption_rules` 两处，产生 dual-source 漂移（这正是「多层兜底/多份状态」的味道）。NULL = "用 legacy 派生默认" 是单一真相源。**移除触发条件**：待 web 编辑面上线、存量 campaign 都迁移到显式规则树后，起 followup change 删 legacy 列 `interruption_whitelist` / `interruption_min_duration_ms`（本 change 在注释里标注该 followup）。

**Alternatives**：(A) 回填 JSON——dual-source；(B) 直接弃用 legacy 列、强制所有 campaign 配树——破坏向后兼容、需一次性数据迁移所有存量。

### D5. 吸收 text-length-gate（VAD-source cancel deprecate）

并入被吸收 change 的决策（verbatim 沿用其 design D2）：`_vad_monitor` **删** `speaking_task.cancel()` + `source="vad"` transcript 写入，**保留** `session.vad_voice_active_ms` mirror（`_partial_monitor` 的 550902d 防自环 corroboration 仍需要）。barge-in 触发唯一入口 = `_partial_monitor` 走规则树。`interruption-detection-text-length-gate` 标 SUPERSEDED，随本 change archive。**移除触发条件**：corroboration mirror 待有替代防自环机制后由 followup 删。

### D6. 删 low_confidence 死分支

- `decider.py`：删「无规则命中 → 主裁判 confidence<阈值 → restructure(last_reply, trigger=low_confidence)」整段（现 `decider.py:108-124`）。无规则命中**统一**走 fail-open continue。
- `streaming/types.py`：删 `FAILOPEN_LOW_CONFIDENCE` 常量及 `effective_category` 里返回它的分支。
- `restructure_trigger` 取值集去掉 `"low_confidence"`；`pipeline_trace.py` / `schemas/jsonb/routing_rule.py` 文档注释去 low_confidence 措辞。

**Why**：该分支因 `referee.py` 硬编码 `confidence=1.0` 恒不触发（已验证），删除对运行时行为**零影响**，纯去死代码 + 文档诚实化。`restructure_trigger` 字段本身保留（`interrupt_remaining` 等仍用），只去一个永不写入的取值。

### D8. `primary_referee_label` 一并从 5 仓拔除（apply 期决策，用户拍板"拔干净"）

apply 期发现：`campaign.primary_referee_label` 列的**唯一功能消费者**就是 D6 删掉的 low_confidence 死分支（其 model 注释自述 "NULL → no low-confidence restructure"），但它横跨 engine（runtime_config / run_loop / decider / prompt_builder）、common（model + schemas.campaign×2 + schemas.pipeline）、api（routing_validation / schemas / campaigns router / role_configs 的裁判删除保护）、web（types + RoutingRulesTab.vue + ToolsTab.vue）。删 low_confidence 后它纯属 vestigial。

**决定（用户拍板）**：本 change **一并拔除** `primary_referee_label`，不留 vestigial 列——
- common：alembic 同一支 migration `drop_column("campaign","primary_referee_label")`（与 `add interruption_rules` 合并）；model / schemas.campaign / schemas.pipeline 去字段。
- engine：runtime_config / run_loop / decider（signature 去 param）/ prompt_builder 去 plumbing。
- api：schemas / campaigns router 去字段；routing_validation 去 `primary_referee_unknown` 校验；role_configs 的"裁判被 primary_referee_label 引用则不可删"保护改为仅 routing_rules 引用判定。
- web：types/campaign.ts + RoutingRulesTab.vue + ToolsTab.vue 去该字段 UI。
- 各仓 test 同步去引用。

**Why over 延后**：留一个"为已删行为服务、跨 5 仓还带 UI"的死列正是要避免的 vestigial 债；趁同一 change 上下文一次拔净（large-change momentum）。**Trade-off**：change 体量与 web 工作量增大；migration 含 drop_column（rollback 时需重建列，下方 Migration Plan 注明）。

### D7. 规则树校验放在 isales-api + common schema

递归 Pydantic discriminated-union（按 `type` 判别）做结构校验；api 写入 endpoint 复用 schema 校验 + 加**深度/节点数上限**（防恶意超深树）+ regex 叶子的 pattern 长度上限（缓解 catastrophic backtracking，见风险）。engine 侧 `build_rule` 对非法 type 抛错并在装配期 fail-fast（坏配置不进运行时）。

## Risks / Trade-offs

- **[regex 叶子的 ReDoS]** 客户自填 regex 可能 catastrophic backtracking 卡住 `_partial_monitor` → **Mitigation**：api 校验限制 pattern 长度（如 ≤128 char）+ 文档警示；`re.search` 在每个 partial 上对短文本跑（partial 通常 <50 字），风险有限；若实测有问题，followup 换 `google-re2`（线性时间）。注明此为已知边界。
- **[默认树 vs 现状不等价]** 合成默认树若与现序列有差 → **Mitigation**：默认树严格用 `exact` keyword + length(2) + duration，单测**逐 case 对拍**现 `evaluate_partial`（同输入同 verdict）；smoke 复跑 #136 数据。
- **[规则树编译失败导致整通话起不来]** 坏 JSON → **Mitigation**：`build_rule` 装配期 fail-fast 并 log 明确错误；api 写入即校验，坏配置进不了 DB；运行时 NULL/解析失败回落默认树而非崩溃（这是**唯一**保留的兜底，注明移除条件：api 校验稳定后可改为硬失败）。
- **[low_confidence 删除其实改了行为]** → 已验证是死分支（confidence 恒 1.0），删除零行为变化；若未来 referee 改回真置信度且想要低置信复述，走新 change 显式设计（而非复活死代码）。
- **[Trade-off: keyword 默认 contains 比现 exact 更激进]** 新配置默认子串匹配会让「好啊」也被「好」忽略 → **接受**：仅影响**新**显式配置的 campaign（默认树仍 exact），且子串过滤正是 voxen 实证更贴近真实语气词场景的行为。

## Migration Plan

部署顺序（锁死，避免 schema 与代码错配）：
1. isales-common：加规则树 schema + campaign `interruption_rules` 列 migration（**commit 前跑 `alembic heads/history` 确认 revision id 不撞**）；bump version。
2. isales-engine：规则树模块 + factory + `evaluate_partial` 改造 + `runtime_config` 装配 + `_vad_monitor` 去 cancel + `decider`/`types` 删 low_confidence；pin 新 common；pytest 全绿。
3. ECS：alembic upgrade（加 `interruption_rules` 列，存量行 NULL）→ scp engine 改动 + 升级 common wheel → `systemctl restart isales-engine` → journalctl 验证无 import/config 错。
4. mac dev-no-modem 真 mic smoke：默认树 campaign 复跑 #136（AI 长回应 `interrupted=false`、0 误触发）；再配一棵显式规则树验证 keyword(contains)/regex/and-or-not 生效。
5. isales-api 校验 endpoint + isales-web 编辑面（**分阶段**，可在 engine 上线后单独 task section 推进）。

**Rollback**：engine revert 3 文件 + scp 旧版 + restart（5 分钟）。`interruption_rules` 列 schema-additive（NULL 默认），旧代码不读该列，DB 无需回滚。

## Open Questions

- **Q1**：规则树深度/节点数上限取多少？→ 暂定深度 ≤ 8、节点 ≤ 64，apply 时定，api 校验执行。
- **Q2**：legacy 列 `interruption_whitelist` / `interruption_min_duration_ms` 何时删？→ 待 web 编辑面上线 + 存量 campaign 迁移到显式树后，followup change `interruption-rules-drop-legacy-columns`（D4 移除触发条件）。
- **Q3**：`length` 按 char 还是 utf-8 byte？→ 沿用现状 `len(text.strip())`（char/rune），中文 1 字 = 1。
- **Q4**：web 编辑面是嵌进 active change `web-admin-scene-single-page-config` 的场景表单，还是本 change 独立 task section？→ apply 时按 web 仓当时进度定；schema 契约本 change 已定。
