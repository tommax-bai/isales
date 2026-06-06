## Why

承接 `engine-flat-refactor-blueprint.md`：change-1（`engine-eventbus-foundation`，已 archive）建好了进程内双车道 EventBus；本 change 是扁平化重构的**第 2 步**——引入 **`SelectRouter` 效果路由表**：把每轮用户对话 `decide()` **之后的「下一步效果分发」**（goal_achieved / transfer / customer_decline / restructure）从 `_main_turn_loop` 的内联 if/elif 抽成一张路由表，躲在 kill-switch `ENGINE_USE_ROUTER`（默认 OFF）之后，**生产行为逐字节不变**（change-0 golden-transcript 网兜底）。

为何先走这一步：change-3 要把挂断 / 转人工做成 tool route、把效果落地从 run_loop 抽出。先立起「`DeciderAction` → effect-route」这张表（与 legacy 内联并存、默认走 legacy），change-3 往表里加 tool route / 改 gating 就能局部化、可灰度、可回滚。

**两次范围收窄（记录以免来回）**：
1. blueprint §5 原把 `StatusProjector`（FSM→事件投影）放 change-2。对抗 review 证：用进程内 bus 的**异步**派发做 projector 会打乱 `session.state` 写序、丢 `transition_to` 副作用、且与 iSales **开口后** referee 时序冲突——kill-switch 下做不到逐字节。→ projector + call-state-machine 改写整块**移交 change-3**（见 design D5）。
2. 收窄后第一版仍让 Router 按 voxen 式包住「eager dialogue + play + eval + decide + effect」。apply 读真代码（run_loop 566-937）发现：那要整体复制 ~370 行轮次机制（transfer/protection/filler/play/打断/wrap-up——绝大部分不是「路由」），byte-identity 风险高且 3 个 golden 里只 2 个走用户轮。→ **Shape B**：Router 只做 `decide()` **之后**的效果分发；对话/播放/referees/decide/wrap-up/tail 全 inline verbatim。eager-dialogue-route + live-generator deviation 随 change-3 的 eager 多人设一起落（届时 N>1 racing 才真用得上）。

## What Changes

> Engine-only。无 isales-common / 无 alembic / 无跨仓。**不碰 call-state-machine / 状态机 / projector / `_publish_status`**（整块移交 change-3）。

- **新增 `select_router.py`**：`ExecutableRoute` 协议 + `RouteResult` + `Directive`（continue / return / fall_through）+ `Router`（routes 表 + selector；`dispatch(action, ctx)` 选 route 并 execute，不 catch 异常以保 byte-identity）。Router **不**包对话/播放/referees/decide。
- **新增 `routes/`**：`effects.py`（4 条 effect-route：`GoalAchievedRoute` / `TransferRoute` / `CustomerDeclineRoute` / `RestructureRoute`，各 `execute(ctx)` 复用现有 run_loop 效果函数**同序同参**、返回 Directive）+ `selector.py`（`DeciderAction`→route-id）+ `builder.py`（构造 Router）。
- **新增 settings `ENGINE_USE_ROUTER`（默认 OFF）**：`run_loop` 在用户轮 838 的 `if not is_wrap_up:` decider 分支处据此二选一（legacy 内联 vs `router.dispatch`）。**removal trigger = change-3 Phase-4**。
- **明确不动（inline verbatim）**：`decide()`、`run_pipeline_stream`、`_play_streaming` / `_SynthJob`、`_await_referees`（开口后 2.0s fail-open）、`_assemble_interrupt_text`、final-coalescing、cross-turn 计数器、greeting 顺序、text≥2 门、wrap-up 处理（910-935）、restructure-cap-reset（908）、LISTENING tail（937）、`_perform_handoff` / `_run_restructure`（被 route 复用，函数本体不改）、所有 `transition_to` / `_publish_status`、shielded finalize + DECR snap-to-0 + post-call extractor、barge-in reach-across。

## Capabilities

### New Capabilities
<!-- 无新增 capability -->

### Modified Capabilities
- `ai-pipeline`: **ADDED**「SelectRouter 效果分发（kill-switch ENGINE_USE_ROUTER）」——把 `decide()` 之后的效果分发描述为 effect-route 表（route 复用现有效果函数 + 返回控制指令），默认 OFF 逐字节不变。**纯 ADDED**：flag-OFF 下现有 decider / 编排 requirement 字面仍真；flag-ON 行为由这条新 ADDED 描述。新头名与 active 的 `referee-hangup-action`（MODIFIED decider）**不重名** → archive 不互踩。**不碰 call-state-machine**（projector 移交 change-3，连带消除与 `call-state-machine-soften-guard` 的潜在重叠）。

## Impact

- **isales-engine**：新增 `select_router.py` / `routes/*` + settings flag；`run_loop` 效果分发处加 flag 分支。**驱动循环 / play / referees / decide / wrap-up / tail / 状态机 / `_publish_status` / finalize 零改动**。动 `settings.py` 已先 `git stash` 多-Edge gRPC WIP（stash@{0}），收尾 pop。
- **测试**：`test_select_router.py`（selector + dispatch + 异常传播）+ `test_effect_routes.py`（4 route 与 legacy 内联同序同参 + 同 Directive）；golden net **双 flag 跑**（OFF 验 legacy；ON 验 3 确定性场景逐字节，goal_achieved_wrapup 覆盖 GoalAchievedRoute）。transfer / customer_decline / restructure route 真机逐字节 defer change-3 真机 gate（靠单测）。
- **无 isales-common / 无 alembic / 无跨仓**。
- **archive 纪律**：本 change 须在写 change-3 的 ai-pipeline MODIFIED delta **之前** archive（蓝图 §5）。
