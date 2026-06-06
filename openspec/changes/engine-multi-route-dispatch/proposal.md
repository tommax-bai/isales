## Why

承接 `engine-flat-refactor-blueprint.md`：change-1（`engine-eventbus-foundation`，已 archive）建好了进程内双车道 EventBus；本 change 是扁平化重构的**第 2 步**——引入 **`SelectRouter` 多路决策分发**：把每轮用户对话的「跑 referees + 选下一步」从 `_main_turn_loop` 的内联 if/elif 决策抽成一个**复用 `decide()`** 的 Router，躲在 kill-switch `ENGINE_USE_ROUTER`（默认 OFF）之后，**生产行为逐字节不变**（change-0 golden-transcript 网兜底）。

为何先走这一步：change-3 的行为变化（referee 开口前 gating、eager 多人设、挂断 / 转人工 tool route）若直接在 ~470 行的 `_main_turn_loop` if/elif 阶梯上动刀，风险无法隔离。先把「跑 referee + 决策选路」抽成 Router 抽象、与 legacy 内联决策并存、默认走 legacy，change-3 的行为改动就能局部化、可灰度、可回滚。

**范围调整（对抗 review 结论，见 design.md D5）**：blueprint §5 原把 `StatusProjector`（FSM→事件投影、单写者）也放在 change-2。自审发现：用进程内 bus 的**异步**派发做 projector 会打乱 `session.state` 写序、丢失 `transition_to` 的 `previous_state` / `state_history` / `state_warning` / `state_changed` 副作用、且与 iSales **开口后**（post-reply）referee 时序冲突——在 kill-switch「行为零变化」前提下**做不到逐字节**。故本 change **只做能逐字节的那半（SelectRouter 决策分发）**；`StatusProjector` + call-state-machine 的 controller→投影改写整块**移交 change-3**（与真行为变化一起做、golden 重生，projector 直接落 async 版、不造一个 change-3 又要推翻的同步过渡件）。

## What Changes

> Engine-only。无 isales-common / 无 alembic / 无跨仓。**本 change 不碰 call-state-machine / 状态机 / projector / `_publish_status`**（整块移交 change-3）。

- **新增 `select_router.py`**：`Router` + `ExecutableRoute` 协议 + `RouteResult`。change-2 是其 **N=1 对话 route 退化形态**：eager 启动 1 条对话 route（交出 **started `PipelineStream`、`sentences()` 未迭代**——live-generator deviation，design.md D3）→ 播放（复用 `_play_streaming`）→ **开口后** referees 作 `eval_fn` → `decide()`（**原样复用**）作 selector 选下一步 effect-route。N>1 投机多人设 + tools = change-3。
- **新增 `routes/`**：`dialogue.py` / `restructure.py` / `referees.py`（eval_fn，包现有 `_await_referees`，**2.0s fail-open + 开口后时序不变**——→600ms gating 是 change-3）/ `selector.py`（`DeciderAction`→effect-route 映射）/ `builder.py`（从 `PipelineConfig` 构造 Router）。
- **新增 `turn_controller.py`**：flag-ON 下的**用户轮处理器**——复现 run_loop 现有「PROCESSING → `run_pipeline_stream` → play → await referees → `decide` → 施 effect」（≈ run_loop.py 626-908）的等价路径，但决策计算经 Router。**驱动循环 `_await_user_or_silence`（含 final-coalescing）+ silence / no-progress / remote-hangup 分支 + 所有 `transition_to` + `_publish_status` + finalize 全部 verbatim**——只有「用户轮的决策计算」改道。
- **新增 settings `ENGINE_USE_ROUTER`（默认 OFF）**：`run_loop` 在用户轮处理上据此二选一（legacy 内联 vs Router）。**removal trigger = change-3 Phase-4**（删 legacy 决策块 + flag 的同一 commit）。
- **明确不动**：`decide()`、`_await_user_or_silence`（含 final-coalescing）、`_play_streaming` / `_SynthJob`、`_assemble_interrupt_text`、cross-turn 计数器、greeting 非打断顺序、text≥2 门、wrap-up 关 referee、the ONE `chat_stream→chat` fallback + `default_reply` guard、`_perform_handoff`、所有 `transition_to` / `_publish_status`、shielded finalize + DECR snap-to-0 + post-call extractor、barge-in reach-across（2.5 移交 change-3，真机 gate）。

## Capabilities

### New Capabilities
<!-- 无新增 capability -->

### Modified Capabilities
- `ai-pipeline`: **ADDED**「SelectRouter 多路分发（kill-switch ENGINE_USE_ROUTER）」——把每轮用户对话的决策分发描述为 Router 编排（eager dialogue live-generator + **开口后** eval_fn referees + 复用 `decide()` + effects/驱动/状态机 verbatim），默认 OFF 逐字节不变。**纯 ADDED**：flag-OFF 下现有 decider / 编排 requirement **字面仍真**；flag-ON 行为由这条新 ADDED 描述（复现同样 to-state / reason）。新头名与 active 的 `referee-hangup-action`（MODIFIED 路由规则引擎 decider）**不重名** → archive 不互踩。**本 change 不再碰 call-state-machine**（projector 移交 change-3，连带消除与 `call-state-machine-soften-guard`（MODIFIED 状态集合）的潜在重叠）。

## Impact

- **isales-engine**：新增 `select_router.py` / `routes/*` / `turn_controller.py` + settings flag；`run_loop` 用户轮处理加 flag 分支。**驱动循环 + 其余分支 + 状态机 + `_publish_status` + finalize 零改动**。动 `settings.py` 时须先 `git stash` working-tree 的多-Edge gRPC WIP（参照 change-1 2.6）。
- **测试**：router / routes 单测 + eager live-generator 回归（断言 `route.execute` 返回时 `sentences()` 尚未迭代、`_play_streaming` 仍是唯一消费者）；golden net **双 flag 跑**（OFF 验 legacy 原样；ON 验 3 确定性场景逐字节——P2 下逐字节是**结构性**的：同 effect / 同 transition / 同 finalize，仅决策计算改道）。barge-in / 转人工 ON 路径仍 defer change-3 真机 gate。
- **无 isales-common / 无 alembic / 无跨仓**。
- **archive 纪律**：本 change 须在写 change-3 的 ai-pipeline MODIFIED delta **之前** archive（蓝图 §5；change-3 与本 change 都碰 ai-pipeline）。
