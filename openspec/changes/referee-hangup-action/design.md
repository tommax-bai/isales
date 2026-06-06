## Context

`engine-multi-referee-and-restructure`（2026-06-05 归档）确立了「N 裁判并行 → 有序 routing_rules → decider 第一命中即生效」的二级决策。当前 `RoutingAction` 是 `TransitionAction | RestructureAction` 的 discriminated union（按 `type`）。decider 命中后只能：转移状态（goal_achieved→WRAPPING_UP / transfer→handoff / customer_decline→恢复）或切重组流。

主动挂断的能力当前**只存在于非裁判路径**：静音超时（`silence_max_reached`）、无进展超时（`no_progress_timeout`）、人工（`manual_hangup`）、对方先挂（`user_hangup`）、正向收尾完成（`wrap_up_completed`）。裁判即便判出「客户骂人 / 明确驱赶」也无法触发挂断——只能走 `customer_decline`（兜底继续）。

约束：① `HangupCause` 是唯一权威枚举（call-state-machine § hangup_cause 单一来源），新增 cause 必须先扩枚举 + 改 spec；② routing_rules 为 JSONB、元素由 Pydantic schema 校验，无 DDL；③ v1 无真实生产数据，旧 campaign 不含 hangup 规则即行为不变。

## Goals / Non-Goals

**Goals:**
- 让运营把某个裁判 category 映射到「主动挂断」，AI 当场结束通话。
- 支持可选「挂断前话术」：礼貌告别后挂断，或立即挂断。
- 用专门的 `HangupCause.REFEREE_HANGUP` 记录该终态，且不触发自动重拨。
- 顺带修复动作编辑器目标切换时 `goal_type` 残留导致 422 的缺陷。

**Non-Goals:**
- 不做 per-rule 处置桶配置（do_not_call vs 普通不重拨）——v1 固定「不自动重拨、不自动跟进」，per-rule disposition 留后续。
- 不把挂断前话术做成模板变量 / 走 LLM 生成——v1 是固定字符串，经既有定值 TTS 路径播放。
- 不做 RoutingRulesTab 更大范围的 422/409 报错可读化（独立 usability，本次只修会导致保存失败的 goal_type bug）。
- 不改 `do_not_call` 识别路径（关键词 / 独立 LLM）——与本动作正交；运营若要勿打用既有机制。

## Decisions

### D1：独立 `HangupAction(type="hangup")`，并入 RoutingAction union（不复用 TransitionTarget）
`RoutingAction = TransitionAction | RestructureAction | HangupAction`，按 `type` 区分。`HangupAction = {type: "hangup", closing_phrase?: str|None}`。
- **理由**：挂断是生命周期**终态**，不是转移到某个对话状态；`TransitionAction` 的 `to`=对话状态 + `goal_type` 校验器语义都不适配；hangup 需要 `closing_phrase` 参数，塞进 TransitionAction 会污染其 validator。
- **备选（否决）**：给 `TransitionTarget` 加 `"hangup"` 值。否决——会让「transition 到一个非对话状态」语义混乱，且 `goal_type` 校验器要为 hangup 开特例。

### D2：可选 `closing_phrase`——非空则播一句再挂，为空立即挂
复用既有定值 TTS 路径（`silence_hangup_phrase` 已是「定值字符串 → TTS → 挂断」同款）。
- **理由**：客户骂人 → 立即挂（空话术）；客户「我在忙别打了」→ 礼貌告别再挂（配话术）。两种真实诉求都覆盖。
- **备选（否决）**：① 强制必填话术——否决，立即挂场景需要空；② 走 main/restructure LLM 生成告别语——否决，多余延迟 + 不确定性，终态话术要确定、便宜、可控。

### D3：新增 `HangupCause.REFEREE_HANGUP = "referee_hangup"`
归类为「应用层、本端主动挂断」，与 `manual_hangup` 同族。
- **理由**：命名点明触发源（裁判判定），与 `manual_hangup`（人工）平行清晰；retry-followup 据此判定不重拨。
- **备选（否决）**：`ai_proactive_hangup`——较泛，不如 `referee_hangup` 精确指向决策来源。

### D4：状态机集成——hangup 动作走专门终态路径，不复用 WRAPPING_UP
decider 命中 hangup → 返回 `DeciderAction(kind="hangup", closing_phrase=...)`。run_loop：若 `closing_phrase` 非空，经定值 TTS 播放该句（不新增对话轮、不 spawn referee）；随后 `sm.transition_to(END, reason="referee_hangup")`，由 modem-controller / RTC 执行物理挂断，`call_lifecycle` 落 `hangup_cause=referee_hangup`。
- **理由**：WRAPPING_UP 带「正向收尾、可多轮（`wrap_up_max_rounds`）、goal 语义」，复用会混淆。专门终态路径边界清晰、有界（至多一句）。
- **备选（否决）**：复用 WRAPPING_UP 且把轮次压到 0——否决，语义错位（这不是「达成目标后的收尾」）。

### D5：`customer_decline` 与 `hangup` 的边界（运营文档 + spec 写明）
- `customer_decline`：软拒绝，AI **继续兜底挽留**（ACTIVATING→LISTENING 恢复），不挂断。
- `hangup`：硬终止，AI **结束并挂断**（可选先告别）。
- 运营选用指引：希望再争取一轮 → decline；明确该停止（辱骂 / 强烈驱赶 / 合规风险）→ hangup。

### D6：retry-followup 归类——`referee_hangup` 不自动重拨、不自动跟进
- 加入 retry-followup「不重试的失败场景」（与 `call_rejected` 同列：本端主动结束 = 用户明确拒绝/合规终止，重拨矛盾）。
- 它**不在**跟进 cause 集合（`{normal_clearing, wrap_up_completed, silence_max_reached}`）内，故天然不进跟进队列——与 `manual_hangup` 行为一致。
- **不**默认置 `do_not_call`：勿打是更强的合规标记，仍由既有关键词 / 独立 LLM 路径负责；二者可叠加（裁判挂断 + 关键词命中 → do_not_call）。

### D7：pipeline_trace 不新增列
`matched_rule` 已记录命中规则快照（现在可能是 hangup action），足以追溯。restructure_* 字段与本动作无关。避免无谓 schema 变更。

### D8（web）：动作编辑器目标切换清理 `goal_type`
动作编辑器现支持三类 type（transition / restructure / hangup）。切 type 时按既有 `onActionTypeChange` 重置为该类默认值；**新增**：transition 内部 `to` 从 `goal_achieved` 切到其它目标时 MUST 清空 `goal_type`（修现有 422 bug）。hangup 类型 UI 仅暴露可选话术输入。

## Risks / Trade-offs

- **[裁判误判导致误挂断]** → 缓解：hangup 是 per-rule opt-in，默认不存在；命中受 `CONFIDENCE_THRESHOLD=0.7` 置信下限约束；运营自行调裁判 prompt + 阈值。属产品策略风险，非机制缺陷。
- **[配了话术但对端已先挂]** → 缓解：播放前/中检测会话已 END / RTC 已断，则跳过话术直接 finalize（与现有 SPEAKING 期 user_hangup 处理一致）。
- **[跨仓版本错位]** → 缓解：isales-common bump 版本，engine/api/scheduler pin 同步 lockstep（CLAUDE.md 跨仓纪律）。
- **[referee_hangup 与 do_not_call 语义重叠]** → 明确：referee_hangup=不重拨终态；do_not_call=合规勿打名单。本动作不自动置 do_not_call；如需，运营叠加既有勿打机制。文档写清，避免误以为「裁判挂断=拉黑」。
- **[「多层兜底」嫌疑]**（CLAUDE.md 反模式自检）→ hangup **不是**第四层兜底：它是 decider 的一种**正常 outcome**（与 transition / restructure / continue 并列的产品行为），不是「main 没产出时的救援」。无移除条件，是产品能力。

## Migration Plan

1. isales-common：加 `HangupAction` + union 成员、`HangupCause.REFEREE_HANGUP`；bump 版本（0.7.x → 0.8.0）。无 alembic DDL（routing_rules JSONB / hangup_cause String 列）。
2. engine / api / scheduler：pin `isales-common>=0.8,<0.9`；engine 实现 decider + run_loop + cause 解析；api 校验 closing_phrase。
3. web：动作编辑器加 hangup + 修 goal_type bug；types/campaign.ts 补类型。
4. 部署：按既有 ECS 流程（common 先发、再 engine/api/web）。
5. **回滚**：纯增量——旧 routing_rules 不含 hangup 规则，回滚 common/engine 后仍合法解析；无数据迁移需逆转。唯一注意：若已有 campaign 配了 hangup 规则后回滚 engine，旧 engine 遇未知 action type 应 fail-open 当 continue（实现需保证未知 action 不 crash）。

## Open Questions

- hangup 是否需要 per-rule 处置桶（`disposition: do_not_call | no_retry`）？v1 固定 no_retry，留待真实运营反馈再加。
- closing_phrase 是否支持 `{{customer_name}}` 等模板变量？v1 固定字符串，后续按需。
- 是否需要「连续挂断保护」（极端配置下每轮都挂）？——挂断即终态，单通内不会循环，无需封顶（区别于 restructure）。
