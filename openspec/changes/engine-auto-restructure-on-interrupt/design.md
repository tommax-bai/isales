## Context

barge-in 在 iSales 引擎里是**确定性**判定：SPEAKING / FILLER 期间 `_partial_monitor`（`run_loop.py`）对每个 ASR partial 跑可组合规则树 `evaluate_partial`，命中即 cancel 当前 TTS、置 `session.interruption_signaled`、并把 main 残留未送 TTS 的尾巴写进 `session.interrupt_remaining_text`（`run_loop.py:1033-1035`）。**无 LLM、无 referee 参与检测**。

打断之后"续说自己的话还是回应用户"则走门控：用户 ASR final → N 个 referee 并行分类（gate-first，每轮必跑）→ `decide()`（`pipeline/decider.py:48-114`，纯函数，first-match-wins）按 campaign `routing_rules` 出一个 `DeciderAction`。其中 `restructure` 是 route 之一：按 `source` 取 `interrupt_remaining`（被打断尾巴，`_assemble_interrupt_text` `run_loop.py:1593` take-and-clear）或 `last_reply` 重组复述，跑完直接回 LISTENING、不再过 referee。`decide()` 无命中时缺省落 `continue`（fail-open 到 main，回 LISTENING）。

今天要触发"被打断 → 重组复述残留"，运营必须手写一对 `referee + routing_rule`。本变更把这条最常见路径做成一个 campaign 开关，无需手写规则。

参照对象 voxen（iSales 重组概念来源）的结论一致：voxen 也用 referee 把用户插话分 POSITIVE / NEGATIVE，NEGATIVE（没营养）才路由到 `restructure_stream` 复述机器人自己被切的那句——即 referee 是重组的前置判官，不是被绕开的对象。

## Goals / Non-Goals

**Goals:**
- 加一个 campaign 级开关，让"被 barge-in 打断且无显式规则命中 → 自动复述残留（restructure）"无需手写 `referee + routing_rule` 即可启用。
- 完整保留 gate-first：referee 仍在前、显式 routing rule 仍 first-match-wins，作为自动重组的 veto。
- `decide()` 保持纯函数；自动改判在调用点完成。
- 开关 OFF（默认）时行为与引入前逐字节一致。

**Non-Goals:**
- **不**改 barge-in 检测（规则树 `_partial_monitor` 不动）。
- **不**采用"先放重组音频、再过 referee"（output-then-gate）拓扑——违反 gate-first 且时序错误（见 D1）。
- **不**改 restructure LLM 的输入契约（仍只 `{system, user=InterruptText}`，不带 history / 用户最新一句）。
- **不**新增第二个分类器去判"插话是否有营养"——复用既有 referee + 规则的 first-match-wins，避免多层兜底。
- **不**覆盖 `source=last_reply`（"用户没接住"无 barge-in 场景）：本开关只接管 barge-in 残留（`interrupt_remaining`）；`last_reply` 仍只能由显式规则触发。

## Decisions

**D1 — 拓扑：保留 referee 在前，restructure 作开关控制的缺省出口；拒绝 output-then-gate。**
用户最初设想"引擎报打断状态 → 直接调重组 → 重组后再过 referee"。拒绝原因：(a) 重组音频必须等用户 ASR final 才能出声，否则盖在还在说话的用户上 = 二次抢话；(b) 一旦等到 ASR final，referee 本就要为本轮出话跑一遍（gate-first，0 额外调用），把它放后面既违反 gate-first（放音前审）又丢掉"插话有没有营养"这条让重组用对的唯一信息。故实现的是 referee-first + restructure-as-fall-through，由开关控制；这与用户最终确认的"保留 referee 把关、referee 当否决者"一致。

**D2 — 机制：call-site override，`decide()` 保持纯。**
在 `run_loop.py:1296` `action = decide(...)` 之后、`_select_gated_route` 之前加单一分支：
```
if (action.kind == "continue"
        and config.pipeline.auto_restructure_on_interrupt
        and config.pipeline.restructure is not None
        and session.interrupt_remaining_text):
    action = DeciderAction(kind="restructure",
                           source="interrupt_remaining",
                           restructure_trigger="interrupt_remaining")
```
不动 `decide()`（不在纯函数里读 session / 开关），不合成假 `RefereeResult` / 假 routing rule。这是 `decide()` 唯一会被外部改判的点，且只在缺省位接管。

**D3 — 触发谓词 = `interrupt_remaining_text` 非空。**
该字段非空 ⟺ 上一轮 main 确实被 barge-in 打断并捕获了残留。用它而非 `interruption_signaled`（后者每轮 turn-entry 被清）作为"本轮该续说"的稳定信号。`take-and-clear` 语义不变（`_assemble_interrupt_text` 取用后清空），自动路径与显式路径共用同一构造逻辑。

**D4 — veto = first-match-wins，referee + 显式规则即否决者。**
任一显式 routing rule 命中（`judge_reject=OPERATOR → tool:transfer`、`judge_intent=NEGATIVE → recovery`、`goal_achieved → closing` …）会让 `decide()` 返回非 continue 的 action，自动改判分支因 `action.kind != "continue"` 不触发。即开关只接管"所有 referee 都没命中任何显式规则"的缺省位——那正是"插话没落进任何已知意图"的位置，复述续说是合理缺省。

**D5 — 极性权衡（关键风险，见 Risks）。**
开关 ON 后，被打断轮的缺省由"回应用户（continue 放行 main 回复）"变成"续说自己的话（restructure）"。代价：若一句**真异议**没有被任何显式 routing rule 接住（运营没配对应规则），它会落到缺省位 → 被自动续说盖过、用户输入被忽略。故开关默认 OFF、opt-in，且文档建议开启者务必配齐挂断 / 转人工 / 拒识等否决规则；最适合"打断绝大多数是垫词 / 语气词"的 campaign。

**D6 — 不是多层兜底气味。**
这是单条、开关门控、文档化的**主特性分支**，不是防御性 just-in-case；注释 MUST 点明触发条件（开关 + restructure slot + `interrupt_remaining_text` 非空 + decider 缺省 continue）。它复用既有 restructure route 与 `max_continuous_restructure` 封顶，不新增并行兜底路径，符合 `[[feedback-avoid-multilayer-fallback]]`。

**D7 — 观测：复用 `restructure_trigger="interrupt_remaining"` + `matched_rule=None`，不动 pipeline_trace schema。**
自动改判产生的 restructure trace 与显式 `source=interrupt_remaining` 同值（spec 限定 `restructure_trigger` ∈ {last_reply, interrupt_remaining}，不引入新枚举）；"自动 vs 显式"由 `matched_rule is None` 区分，并加一行 `logger.info("auto_restructure_on_interrupt fired ...")`。无需改 `pipeline_trace`。

## Risks / Trade-offs

- [真异议未被显式规则接住 → 被自动续说忽略]（D5）→ 缓解：默认 OFF + opt-in；文档强调配齐否决规则；仅 barge-in 残留场景触发，不影响无打断轮。
- [NOT NULL 列加到已有 campaign 表] → `server_default=sa.false()` 同 DDL 回填，无 NULL 窗口、无单独数据迁移。
- [api 静默丢弃未知字段] → `CampaignNestedUpdate` 是手维 allowlist，apply 任务显式补该字段并加 round-trip 测试（参照 `interruption-min-chars-and-mode-toggle` 3.2 踩过的坑）。
- [连续自动 restructure 复读] → 复用 `max_continuous_restructure` 封顶，超限改走 default_replies / 连续打断策略；与显式 restructure 同一逻辑。
- [alembic revision id 撞已有] → apply 时先跑 `alembic heads`/`history` 确认；计划 id `a8b9c0d1e2f3`，down_revision `f7a8b9c0d1e2`（见 `[[feedback-alembic-revision-id-collision]]`）。

## Migration Plan

1. `isales-common` 0.8.10 → 0.8.11：model + schema + Alembic 迁移（down_revision `f7a8b9c0d1e2`）。`make test` green。
2. `isales-engine` + `isales-api`：pin → 0.8.11；engine 透传 + call-site override；api 补 allowlist；tests green。
3. `isales-web`：types + `InterruptionTab.vue` 开关 + 文案；`npm run build`（vue-tsc + vite）+ vitest green。
4. Deploy：RDS `alembic upgrade head`，重部署 api / engine / web on ECS，smoke 一次 PATCH round-trip + 一次真机/演练验证"被垫词打断 → 自动续说、真异议打断 → 正常回应"。

**Rollback:** 加性 + 默认保留语义；`alembic downgrade -1` 删列，回退 common pin 即恢复"只能显式规则触发 restructure"。存量 campaign 无数据损失（开关默认 false）。

## Open Questions

- **极性**（D5）：当前选"被打断 → 缺省续说，referee/显式规则 veto"（贴合用户意图）。备选是"必须 referee 显式判 trivial 才续说"（更保守，但要 referee 主动产一个 trivial 类别 + 一条规则，等于回到手写规则）。已采前者；若真机验收发现真异议被忽略过多，再议是否加"仅当所有 referee 均 fail-open 才接管"的更严谓词。
- 是否要把自动 restructure 在 `pipeline_trace` 里显式标注（区别于显式规则触发）？当前用 `matched_rule=None` + 日志，未动 schema；若 ops 需要按"自动重组率"统计再加字段。
