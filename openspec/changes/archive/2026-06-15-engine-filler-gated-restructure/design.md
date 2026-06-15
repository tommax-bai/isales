# Design — engine-filler-gated-restructure

## Context

`engine-auto-restructure-on-interrupt`（archived 2026-06-15）建立了三层分工，本变更只动其中"重组该不该扣动"一位：

| 环节 | 谁做 | 在哪 |
|---|---|---|
| **打断检测**（partial 算不算打断、要不要 cancel TTS） | 引擎确定性规则树（keyword/length/duration） | `realtime/interruption_rules.py` + `_partial_monitor` |
| **状态分类**（成交/拒绝/转人工/继续/**filler**） | **主门控 referee（LLM）** | `referee.py` → `decide()` |
| **重组扣动**（被打断残句要不要顺着说完） | 引擎 override（纯策略，gate 之后） | `run_loop.py` `decide()` 调用点 |

auto_restructure 的 override 现状：`action.kind=="continue" AND 开关 ON AND restructure slot AND interrupt_remaining_text` → 改判 restructure。问题是 `continue` 这一类**同时混着**"无营养垫词打断"和"实质提问打断（无显式规则命中）"，引擎分不开，两种都重组。本变更让主门控用一个保留类别 `filler` 把这两类分开，override 只在 filler 时扣动。

## 决策

### D1 — `filler` 进门控枚举，不进规则树、不做 routing action

"垫词 vs 实质提问"是**语义判断**，正是门控 LLM 的强项；规则树只有 keyword/length/duration 表层条件，无对话语义，塞进去等于要规则树做 LLM 级分类，违背它"便宜、确定、跑在每个 partial 上"的设计。
不做成 routing action（`match:["filler"] → restructure`）：`engine-auto-restructure-on-interrupt` 刚把 restructure 从 routing action 删除、固定为开关驱动；复活它会让规则引擎复杂度回潮，且 api 已拒绝 `to:restructure`。故 filler 走 override 通道（与 auto_restructure 同一通道），只是给 override 多喂一位门控信号。

### D2 — 标签命名用 `filler`，不用 `restructure`

`restructure` 在引擎里已是**动作**标识符（`DeciderAction(kind="restructure")` / `RoleKind.RESTRUCTURE` / `restructure_trigger` / `config.pipeline.restructure`）。门控标签若也叫 restructure，会造成"门控输出 restructure 就直接触发重组路由"的危险误解——而事实相反，它走 override、不进 routing_rules、无残句时等价 continue。门控是**纯分类器**（gate-supervision-rename 的设计共识），输出应是"客户行为类别"（filler = 垫词）而非"引擎动作"。与既有 `goal_achieved` / `customer_decline` / `continue` 同维度（描述对话状态），用小写 `filler` 与生产 seed 风格一致。

### D3 — `restructure_gate_category` 不做 campaign 列（v1）

引擎需要一个识别串。做成 campaign 列要 common/alembic/web/api 全套改动；YAGNI。改为 `PipelineConfig.restructure_gate_category: str = "filler"`（引擎默认，runtime_config 暂不从 campaign 读，用默认），spec 注明可 promote。改动面缩到纯 engine + seed。

### D4 — 占位符注入直接读 `session`，不改 `run_referee` 签名 / 不动 orchestrator

`run_referee(session, user_last_utterance, ...)` **已持有 `session` 首参**（referee.py:72-78）。直接在替换链里读 `session.interrupt_remaining_text` 注入 `{{was_interrupted}}` / `{{interrupted_reply}}`，无需加参数、无需改 `orchestrator.py` 调用点。改动面更小，也避免多调用点签名漂移（`tests/test_referee.py` 也直接调 `run_referee`）。

### D5 — 占位符语义说实话（"上一句残句"而非"本轮是否打断"）

引擎能注入的真实信号是 `bool(session.interrupt_remaining_text)` = "上一句 AI 被打断、留下了没说完的残句"，**不等于**严格意义的"本轮是否为打断"。门控 prompt 文本 SHALL 据实表述为"上一句 AI 是否被你这句话打断、留下残句"，并把 filler 判别绑定为"残句存在 AND 本句纯附和/催促"的联合判断，避免 oversell。

### D6 — 跨轮残句清理（本变更新引入的不变量，必须做）

`interrupt_remaining_text` 全仓**只有一处清**：`run_loop.py:1627` 的 `_assemble_interrupt_text` take-and-clear，**只在 restructure 路径触发**。
现状 override 对所有 `continue+残句` 都重组 → 残句每轮被消费，无残留。
**本变更把实质打断改判为"不重组、正常作答" → 残句不再被消费 → 泄漏到下一轮**：下一轮 `{{was_interrupted}}` 读到陈旧"是"，且 override 守卫 `interrupt_remaining_text` 仍为真 → 若门控在那一轮误判 filler，会重组一句两轮前的陈旧残句。
故 override 分支**必须**配一个 else：本轮有残句但未改判 restructure（开关 ON 下的实质打断）→ 清空 `session.interrupt_remaining_text`。这不是可选优化，是本设计的正确性前提。

### D7 — trace 复用 `interrupt_remaining` trigger，不引入新 trigger

auto_restructure 的 spec 明确"自动改判 MUST NOT 引入新 trigger 枚举值，复用 `interrupt_remaining`"。filler 门控只是收紧了"何时自动改判"，InterruptText 来源（interrupt_remaining）没变。收紧后"自动改判"的唯一形式就是 filler 门控触发，`matched_rule is None` 仍区分自动 vs 显式规则。故复用现有 trigger，不碰那条约束。

## veto 链（收紧后）

被打断 + 开关 ON + 有 slot + 有残句时，下列任一成立即**不**自动重组：
1. 任一显式 routing rule 命中（`action.kind != "continue"`）——原有 veto；
2. 主门控判定为非 `restructure_gate_category`（实质提问/反对/同意/普通继续）——**新增 veto**。
只有"无显式规则命中 AND 主门控判 filler"才自动重组。这正是 auto_restructure proposal 原本的意图（"只有没营养的插话才自动续说"），现在 referee 不再依赖"恰好配了显式规则"才能 veto。

## 非打断兼容（三道闸，逐位等价）

1. **prompt 层**：门控 prompt 硬规则"`{{was_interrupted}}=否` 时绝对不能输出 filler，只在原枚举里选"，原枚举判定逐字对齐。
2. **变量层**：非打断时引擎注入"否 / 空"，门控自然不判 filler。
3. **override 守卫层（兜底）**：即使门控误判 filler，override 条件含 `session.interrupt_remaining_text`——非打断时为 None → 不触发 → `filler` 行为等价 `continue` 正常作答。**filler 在无残句时物理短路成 continue**，正常对话绝不可能被错误重组。

## 对抗评审已吸收的修正

- **override 不引用不存在字段**：早期草案写 `r.label == config.pipeline.referee_fail_open_route_label`——该字段不存在（真实是 `referee_fail_open_route`，值是路由名非 label），且拿路由名比 referee label 永不相等。最终实现只取**主门控那条 referee** 的 `effective_category()` 与 `restructure_gate_category` 比较，不用 `any()`（多 persona referee 时 `any` 会误触）。
- **标签 byte-match routing_rules**：门控输出的存量标签词必须与 campaign `routing_rules[].match` **逐字一致**，否则 `goal_achieved`/`customer_decline`/`transfer` 路由静默失效（回归 camp1 达成率=0）。`filler` 是唯一新增、**故意不进 routing_rules**。见 Open Question OQ1。
- **MECE 收紧**："然后呢/继续"类催促只有当残句**未讲完核心**才 filler，已基本讲完则按实质 CONTINUE；"行行行+具体同意"走 SUCCESS（优先级高于 filler）。few-shot 须含这两个 disambiguation 例。

## OQ 决议（2026-06-15，用户确认）

- **OQ1 已定 — 生产 camp1 用 `HANGUP / SUCCESS / CONTINUE` 大写基线 + 新增 `FILLER`**。该 prompt 把转人工并入 HANGUP、无独立 transfer。生产 camp1 的门控 prompt（部署 task 5.3）写成 `HANGUP / SUCCESS / CONTINUE / FILLER`；其 `routing_rules[].match` 须为 `["HANGUP"]` / `["SUCCESS"]`（部署时 ssh ECS ground-truth 核实 camp1 实际 routing_rules，见 §5）。
- **seed 脚本（demo）与生产 camp1 解耦**：`restructure_gate_category` 是引擎单一全局默认，但它只识别 **FILLER 这一个类别值**——其余标签（seed 的 `goal_achieved/...` vs camp1 的 `HANGUP/...`）各由自己的 `routing_rules` 处理、与 FILLER 检测无关。故 seed 脚本**保持自身 `goal_achieved/customer_decline/transfer/continue` 基线、只新增 `FILLER` 类别 + 占位符**（routing 不动、零路由风险），生产 camp1 用 HANGUP 基线；两者 FILLER 统一，引擎一个默认值通吃。
- **OQ2 已定 — 类别值统一大写 `FILLER`**：引擎默认 `restructure_gate_category = "FILLER"`；引擎默认值、门控 prompt 输出、override 比较串三者一致。

> 早先草稿中小写 `filler` 的表述一律按大写 `FILLER` 实现；spec delta 已统一为 FILLER。change 目录 slug `engine-filler-gated-restructure` 保持小写（kebab-case 惯例，与类别值大小写无关）。

## 风险

- **漏答**（门控把实质提问误判 filler → AI 顺着说完不报价）：prompt 用"有一丝实质就不选 filler"+ 对照 few-shot 压制；且漏答一次代价（下轮客户复述）远小于现状"实质打断被错重组"，是净改善。门控模型若是 qwen-turbo，验收后可视情况升级。
- **两旋钮叠乘**：规则树 `interruption_min_chars`（默认 2）先在 ASR partial 层挡掉太短垫词（"嗯""行"长度<2 不打断、无残句）→ filler 实际覆盖"长度够、确实打断、但语义无营养"的中段（"嗯嗯你继续说"）。`min_chars` 调高会让 filler 少触发——预期行为。
- **连续封顶**：`max_continuous_restructure`（默认 2）下，客户连续垫词催促第 3 次降级为 default_reply——好事（防复读），验收别误判 filler 失效。
- **引擎识别 filler 与"MUST NOT 硬编码枚举"的张力**：通过"单一可配置保留类别 + 等价隐式 match"论证调和（见 spec MODIFIED requirement）；engine 不解释其余枚举语义。
