## Context

扁平化重构第 2 步（`engine-flat-refactor-blueprint.md` §5 表第 2 行：`engine-multi-route-dispatch` / Phase 2 / behavior **none (kill-switch)**）。前置 change-1 已把 ASR / 打断 / 挂断 / lifecycle 信号迁到进程内双车道 `EventBus`（`session.bus`，run_session 入口 start / finally aclose）。今天每轮对话由 `run_loop._main_turn_loop`（481-954）的 `while session.state is not END` + ~430 行 if/elif 阶梯驱动：`_await_user_or_silence`（955-1033，5 种结局 + final-coalescing）→ 用户轮走 PROCESSING(626) → `run_pipeline_stream`(674，eager spawn main+referees) → `_play_streaming`(685，播 live 生成器) → **开口后** `_await_referees`(759) → `decide`(761) → 施 effect(818-908)。本 change 把「用户轮的决策计算」（referees + decide → 选下一步）抽成 `SelectRouter`，与该内联决策并存、默认走内联。

> **范围对 blueprint 的偏离**：blueprint §5 列 change-2 = 「SelectRouter + projector」；change-1 design.md D4 写「`_main_turn_loop` 在 change-2 被替换」。对抗 review（见 D5）证明这两点在 kill-switch「逐字节」前提下做不到。本 change据此收窄：**只抽决策分发，不动驱动循环 / 状态机 / projector**。projector + FSM→投影 + 整循环 push 化 = change-3。

## Goals / Non-Goals

**Goals:**
- `SelectRouter` 决策分发骨架（Router + routes + **开口后** eval_fn），**`decide()` 原样复用**。
- `ENGINE_USE_ROUTER`（默认 OFF）接进 run_loop 的用户轮处理：flag-OFF **零改动**逐字节，flag-ON 决策经 Router 但产出同样 effect。
- golden 双跑（OFF + ON）证 3 确定性场景逐字节。

**Non-Goals:**
- 生产行为变化（flag 默认 OFF）。
- `StatusProjector` / FSM→投影 / call-state-machine delta / 整循环 push 化 —— **全部 change-3**（D5）。
- referee 开口前 gating（post→pre）+ 2.0s→~600ms —— change-3。
- eager 多人设（N>1）/ tools / 挂断·转人工 tool route —— change-3。
- 效果抽进 route 类、barge-in 反转 —— change-3。
- isales-common / alembic / 跨仓 —— 无。

## Decisions

### D1: 纯 ADDED spec delta（仅 ai-pipeline）
本 change 行为 none（kill-switch）→ flag-OFF 下没有任何现有 requirement 变假：`decide()` 原样复用、orchestration 时序不变、`transition_to` / 状态机一字不动。故 spec delta **ADDED-only，且只碰 ai-pipeline**。精确措辞（采纳 collision review）：**flag-OFF 下现有 decider / 编排 requirement 字面仍真；flag-ON 行为由新增的 ADDED requirement 描述**（复现同样 to-state / reason）——不是「现有 requirement 无条件仍真」。新头名 `SelectRouter 多路分发` 与 active 的 `referee-hangup-action`（MODIFIED `路由规则引擎（decider）`）头名不重名，archive 按头名匹配 → 不互踩。**不碰 call-state-machine** → 与 `call-state-machine-soften-guard`（MODIFIED `状态集合`）零重叠。

### D2: 双路径并存 + kill-switch，default OFF
`run_loop` 在**用户轮处理**上读 `ENGINE_USE_ROUTER`。OFF → 现有内联决策（`_await_referees` + `decide` + 818-908 施 effect），原封不动逐字节。ON → `turn_controller` 经 Router 算决策，**施 effect 仍调用同一批 run_loop 函数**。驱动循环 / 其余结局分支 / 状态机 / finalize 与 flag 无关、永远走原路径。按「避免多层 fallback」原则：双路径 + flag 是 removal-tracked 过渡债，**removal trigger = change-3 Phase-4** 删 legacy 决策块 + flag 的同一 commit。

### D3: eager live-generator deviation（最大风险，loud doc + 回归测试）
对话 route 的 `execute` MUST 返回 **started 的 `PipelineStream`**（`stream.start()` 已 spawn main+referees、已 bump `current_turn_id`），但 **`sentences()` 尚未迭代**——下游 `_play_streaming`（run_loop.py:1120 `stream.sentences()`）仍是唯一消费者。这 port voxen `getResult` 语义（其 `wg.Wait()` 只等 `Execute` **返回 handle**、非排空流）。若未来有人「修正」成在 Router 内迭代 / 收集 `sentences()`，**每轮回复哑火**：① 首音频延迟从 1 chunk 暴涨到整段；② 打断无法中途取消；③ orchestrator 逐句计时 + 增量 TTS 推送坍塌。守卫：`test_eager_dialogue_route_returns_live_generator`（断言 Router 返回时 `sentences()` 未被迭代、stream 仍可被 `_play_streaming` 消费）+ loud docstring。保留对在途 stream 的 cooperative cancel（asyncio cancel）。

### D4: Router 保留「开口后」referee 时序（非 voxen 的 eval-before-gather）
iSales referee 是 **post-reply**（先播完回复 685、再 await referees 759、再 decide）。voxen Router 的 `Route()` 是 eval→decide→gather（开口**前**判）。故本 change 的 Router **MUST NOT** 套用 voxen 顺序：其编排 = eager 启动对话 route → **play（live gen）** → eval_fn（referees，开口后）→ `decide`（selector）→ 选下一步 effect-route。开口前 gating 反转（eval-before-play）+ 2.0s→~600ms 是 change-3。这是「change-2 的 Router 不是 voxen 字面 port」的根因，须 loud doc 以免 reviewer 期待 1:1。

### D5: StatusProjector + FSM→投影整块 defer 到 change-3（对抗 review 结论）
blueprint §5 原把 projector 放 change-2。自审证其在 kill-switch 下**做不到逐字节**：① `bus.post()` 异步派发（后台 dispatcher 协程），而 legacy `sm.transition_to` 同步——把 transition 改成 post 事件会让 state 写**延迟**、与周围同步 `append_event` / 读 `session.state`（如 `is_wrap_up`、`_publish_status` 读 state、`_perform_handoff` transition↔append 交错）乱序，破 golden 断的 transcript 顺序；② projector 重写投影会漏 `transition_to` 的 `previous_state` / `state_history` / `state_warning` / `state_changed` 副作用；③ push 化 `on_user_final` 只覆盖「用户说话」，丢 silence / no-progress / remote-hangup 结局（silence golden 场景无用户说话 → 空 transcript）。同步版 projector 虽能逐字节，但要给 ~19 个 transition 点注入 sink，且 change-3 会用 async 版推翻它（造过渡件，违「不做半成品」）。**故 projector / call-state-machine 改写整块 = change-3**，届时整循环已 push 化、golden 重生，projector 一次落 async 版。本 change 不引入任何 projector / `_publish_status` 改动。

### D6: effects + 驱动 + 状态机 verbatim（无 sink 改造）
Router / turn_controller 只算**决策**（选哪条 effect-route）；**effect 执行**（`transition_to(WRAPPING_UP/TRANSFERRING/...)`、`_perform_handoff`、restructure 执行、`default_reply` 兜底、`_play_streaming`）由 flag-ON 分支调用**现有 run_loop 函数**完成——这些函数**一字不改**，仍同步调 `transition_to` / `_publish_status`。因为 change-2 不引入 projector，这些函数继续做唯一物理写者（`session.state` 本来就只有 `transition_to` 一个物理写点），**无 dual-writer、无需 sink 参数化**。这正是 P2 比 P1 干净之处：review 的 dual-writer / sink-contradiction must-fix 不复存在。

### D7: golden net 双 flag 跑；硬件路径 defer
`test_golden_transcript` 参数化 `ENGINE_USE_ROUTER ∈ {off, on}`。OFF MUST 匹配既有 golden（legacy 未动）。ON MUST 对 3 个确定性场景（one_turn_hangup / goal_achieved_wrapup / silence_activation_hangup）匹配**同一** golden——P2 下这逐字节是**结构性**的（同 effect 函数、同 `transition_to`、同 finalize；仅用户轮决策计算改道，输出同样 `DeciderAction`）。silence 场景天然过：驱动循环 `_await_user_or_silence` 不改，silence 结局根本不进 Router。barge-in / restructure / transfer / listen_only 的 ON 路径逐字节断言仍 **defer change-3 真机 UX gate**（golden 不覆盖、需物理 SIM7600 rig）；在此之前生产 flag 保持 OFF。**此覆盖盲区显式记录，不静默截断。**

§6 must-not-drop 在本 change 全部**继承自未改动的 run_loop**：shielded finalize + DECR snap-to-0 + post-call extractor 走 run_session.finally + dial_consumer `finalize_session`（本 change 不碰）；`_play_streaming`/`_SynthJob`(maxsize=2) / `_assemble_interrupt_text` / cross-turn 计数器 / greeting 顺序 / text≥2 门 / wrap-up 关 referee / the ONE `chat_stream→chat` fallback + `default_reply` guard / 每终结路径设 `hangup_cause` 全部由 flag-ON 分支复用原函数保住。

## Risks / Trade-offs

- **[eager-generator 被 drain]** → D3 的回归（Router 返回时 `sentences()` 未迭代）+ loud doc。
- **[Router 顺序错配成 voxen eval-before-gather]** → D4 loud doc + 单测断言 play 先于 eval。
- **[turn_id / effect 顺序漂移]** → 对话 route start = `run_pipeline_stream`（同点 bump turn_id），play 在 effect 前，与 legacy 一致；单测固定序。
- **[flag-OFF 被扰动]** → flag 只在用户轮决策处分支；OFF 不实例化 Router / turn_controller；OFF golden 兜底。
- **[互踩]** → D1 的 ADDED-only(仅 ai-pipeline) + 不碰 call-state-machine 规避。
- **[archive 顺序]** → 本 change 须在 change-3 ai-pipeline MODIFIED delta 前 archive。referee-hangup-action 若被当 stopgap 启用归档，须排在 change-3 ai-pipeline delta 前（与本 change 无关——头名不重名）。

## Migration Plan

Phase 1-6（见 tasks.md）。回滚 = flag OFF（瞬时）或 revert run_loop 的用户轮 flag 分支（新模块即惰性增量）。
