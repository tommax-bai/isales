## Context

扁平化重构第 2 步（`engine-flat-refactor-blueprint.md` §5 表第 2 行：`engine-multi-route-dispatch` / Phase 2 / behavior **none (kill-switch)**）。前置 change-1 已把 ASR / 打断 / 挂断 / lifecycle 信号迁到进程内双车道 `EventBus`。今天每轮用户对话由 `run_loop._main_turn_loop`（481-942）驱动；其用户轮块（566-937）依次：取词 + cheap-transfer + 连续打断保护 + PROCESSING + filler + `run_pipeline_stream`(674) + SPEAKING + `_play_streaming`(685) + **开口后** `_await_referees`(759) + `decide`(761) + trace/ai_reply + **decider 驱动的效果分发**(838-906) + wrap-up(910-935) + LISTENING tail(937)。本 change 把其中 **`decide()` 之后的效果分发**抽成 `SelectRouter` 效果路由表，与内联分发并存、默认走内联。

> **两次范围收窄（均来自对抗 review / apply 实证，记录以免来回）**：
> 1. blueprint §5 列 change-2 = 「SelectRouter + projector」。对抗 review 证 projector 在 kill-switch 下做不到逐字节（D5）→ projector + FSM 投影整块移交 change-3。
> 2. 收窄后第一版 spec 仍让 Router 按 voxen 式「包住 eager dialogue + play + eval + decide + effect」。apply 读真代码（566-937）发现：那要整体复制 ~370 行轮次机制（transfer/protection/filler/play/打断/wrap-up——绝大部分不是「路由」），byte-identity 风险高且 3 golden 里只 2 个走用户轮。**用户拍板 Shape B**：Router 只做 **decide() 之后的效果分发**（D3）；对话/播放/referees/decide/wrap-up/tail 全 inline verbatim。eager-dialogue-route + live-gen deviation 随 change-3 的 eager 多人设一起落（届时 N>1 racing 才真用得上）。

## Goals / Non-Goals

**Goals:**
- `SelectRouter` 效果路由表：`decide()` 的 `DeciderAction` → effect-route → 复用现有效果函数施效 + 返回控制指令。
- `ENGINE_USE_ROUTER`（默认 OFF）接进 run_loop 的效果分发处：flag-OFF **零改动**逐字节，flag-ON 经路由表但施同样 effect。
- golden 双跑（OFF + ON）+ effect-route 单测。

**Non-Goals（全部 change-3）:**
- `StatusProjector` / FSM→投影 / call-state-machine delta / 整循环 push 化（D5）。
- eager 多人设对话 route（N>1）+ live-generator deviation + 开口前 gating（post→pre）+ 2.0s→~600ms。
- 挂断 / 转人工 tool route。
- 效果**逻辑**改写（本 change 只搬位置，不改逻辑）；barge-in 反转。
- isales-common / alembic / 跨仓。

## Decisions

### D1: 纯 ADDED spec delta（仅 ai-pipeline）
本 change 行为 none（kill-switch）→ flag-OFF 下没有任何现有 requirement 变假。故 spec delta **ADDED-only，且只碰 ai-pipeline**：新增「SelectRouter 效果分发」requirement。精确措辞：**flag-OFF 下现有 decider/编排 requirement 字面仍真；flag-ON 行为由新 ADDED requirement 描述**。新头名与 active 的 `referee-hangup-action`（MODIFIED `路由规则引擎（decider）`）不重名 → archive 不互踩。**不碰 call-state-machine** → 与 `call-state-machine-soften-guard`（MODIFIED `状态集合`）零重叠。

### D2: 双路径并存 + kill-switch，default OFF
`run_loop` 在**效果分发处**（用户轮 838-906 的 `if not is_wrap_up:` decider 分支）读 `ENGINE_USE_ROUTER`。OFF → 现有内联 if/elif，原封不动逐字节。ON → `router.dispatch(action, ctx)` 走效果路由表。其余一切（驱动循环、取词、protection、PROCESSING、play、referees、decide、wrap-up、tail、状态机、finalize）与 flag 无关、永走原路径。**removal trigger = change-3 Phase-4** 删 legacy 内联分发 + flag 的同一 commit。

### D3: Shape B —— Router 只做 decide() 之后的效果分发（apply 实证收窄）
seam = `decide()` 之后的 decider 驱动分支（run_loop.py 840-906：goal_achieved / transfer / customer_decline / restructure）。每条分支抽成一条 **effect-route**：`route.execute(ctx)` 调用**现有效果函数**（`sm.transition_to` / `_perform_handoff` / `_run_restructure` / `_play_tts` / `session.append_event`）同序同参，返回控制指令 `continue|return|fall_through`。selector 把 `DeciderAction` 映射到 route（无匹配 = continue/降级 → `fall_through`）。**对话生成 / 播放 / referees / decide / wrap-up(910-935) / cap-reset(908) / LISTENING tail(937) 全 inline verbatim、不进 Router**。理由：复现整条用户轮（566-937）是高风险纯复制且 golden 覆盖差；真正逐字节且对 change-3 有用的是效果路由表（change-3 往表里加 tool route）。

### D4: 对话/referees 保持开口后 inline，Router 不重排时序
referees 仍**开口后**（先 `_play_streaming` 再 `_await_referees`，2.0s fail-open）、`decide()` 仍内联——Router **不**触碰生成/播放/判定时序，只接管判定**之后**的效果落地。voxen 的 eval-before-gather（开口前判）+ gating + 2.0s→~600ms = change-3。

### D5: StatusProjector + FSM→投影整块 defer 到 change-3（对抗 review 结论）
projector 在 kill-switch 下做不到逐字节：① bus 异步派发乱 state 写序（与同步 `append_event`/读 `session.state` 交错）；② 重写投影漏 `transition_to` 的 `previous_state`/`state_history`/`state_warning`/`state_changed`；③ push 化 `on_user_final` 丢 silence/no-progress/remote-hangup 结局。同步版 projector 又会被 change-3 的 async 版推翻（过渡件）。故 projector / call-state-machine 改写整块 = change-3（届时整循环 push 化、golden 重生、projector 一次落 async 版）。本 change 不引入任何 projector / `_publish_status` 改动。

### D6: effect-route 包现有函数 verbatim（无 sink、无 dual-writer）
effect-route 只搬「调用位置」、不改「调用内容」：route 内部调现有 run_loop 效果函数（同序同参），`session.state` 仍由现有 `sm.transition_to` 单一物理写者写（本来就只有它一个写点）。无需 sink 参数化、无 dual-writer——这是 Shape B 比「整 Router」干净之处。route 的控制指令（continue/return/fall_through）精确复刻 legacy 的 `continue`/`return`/落 937 控制流。

### D7: golden net 双 flag 跑 + effect-route 单测；真机 defer
`test_golden_transcript` 参数化 `ENGINE_USE_ROUTER ∈ {off, on}`。OFF 匹配既有 golden；ON 对 3 确定性场景匹配同一 golden。覆盖：`goal_achieved_wrapup` 走 goal_achieved effect-route + wrap-up→END；`one_turn_hangup` 走 user-hangup（不经 effect-route）；`silence` 不进用户轮。**transfer / customer_decline / restructure effect-route 不在 golden**——由新增单测（mock harness 断言与 legacy 内联同序同参）覆盖，真机逐字节 defer change-3 真机 UX gate。生产 flag 在 change-3 前保持 OFF。**覆盖盲区显式记录，不静默截断。**

## Risks / Trade-offs

- **[effect-route 偏离 legacy 控制流]**（continue/return/fall_through 映射错）→ golden ON（goal/hangup）+ 新单测（transfer/decline/restructure）双重兜底。
- **[flag-OFF 被扰动]** → flag 只在 838 的 `if not is_wrap_up:` 处分叉；OFF 不实例化 Router；OFF golden 兜底。
- **[互踩]** → D1 的 ADDED-only(仅 ai-pipeline) + 不碰 call-state-machine 规避。
- **[archive 顺序]** → 本 change 须在 change-3 ai-pipeline MODIFIED delta 前 archive。

## Migration Plan

Phase 1-5（见 tasks.md）。回滚 = flag OFF（瞬时）或 revert run_loop 的效果分发 flag 分支（新模块即惰性增量）。
