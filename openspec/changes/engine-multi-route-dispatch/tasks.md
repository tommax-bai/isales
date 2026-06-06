## 0. 前置 & 纪律

- [x] 0.1 change-1 `engine-eventbus-foundation` 已 archive（2026-06-06，`2026-06-06-engine-eventbus-foundation`）——满足蓝图 §5。
- [ ] 0.2 本 change **纯 ADDED delta、仅碰 ai-pipeline**（SelectRouter 决策分发）。不 MODIFY 任何现有 requirement、**不碰 call-state-machine** → 与 active 的 `referee-hangup-action`（MODIFIED 路由规则引擎 decider）/ `call-state-machine-soften-guard`（MODIFIED 状态集合）**零互踩**。StatusProjector / FSM→投影 / 整循环 push 化 / MODIFIED·REMOVED 全部留 change-3（见 design D5）。
- [ ] 0.3 engine working tree 有一摊**多-Edge gRPC 路由 WIP（9 文件未提交，含 `settings.py`）**——本 change 动 `settings.py`（加 flag）/ 可能动 `run_loop.py` 时须先 `git stash` WIP（参照 change-1 2.6），干净树上做，再 `git stash pop`。

## 1. settings flag（默认 OFF）

- [ ] 1.1 `settings.py`：加 `ENGINE_USE_ROUTER: bool = False`，docstring 注明 removal trigger = change-3 Phase-4。

## 2. SelectRouter 内核（port voxen `core/selectrouter`，change-2 = N=1 退化形态）

- [ ] 2.1 `select_router.py`：`ExecutableRoute` 协议（`route_id` / `metadata` / `async execute(ctx, input) -> Any`）+ `RouteResult`（id / output / decision / err / metadata）+ `Router.route(ctx, input, eval_fn)`。
  - NOTE：**保留开口后时序（design D4）**——编排 = eager 启动对话 route → **play** → `await eval_fn`（referees）→ `decide()` → selector 选 effect-route；**MUST NOT** 套 voxen 的 eval-before-gather。
  - NOTE：**eager-generator deviation（design D3）**——对话 route `execute` 返回 started `PipelineStream`、`sentences()` 未迭代；loud docstring；保留 cooperative cancel。
  - NOTE：change-2 只有 1 条对话 route（N=1），cancel-losers 机制建好但仅平凡触发；N>1 投机多人设 + tools = change-3。
- [ ] 2.2 `tests/test_select_router.py`：route 编排 + eval_fn 闭包 + **`test_eager_dialogue_route_returns_live_generator`**（Router 返回时 `sentences()` 未迭代、stream 仍可被 `_play_streaming` 消费）+ **play 先于 eval 的顺序断言**（守 D4）。

## 3. routes

- [ ] 3.1 `routes/dialogue.py`：eager `DialogueRoute`，`execute` 包 `run_pipeline_stream`，返回 started stream（sentences 未迭代）。
- [ ] 3.2 `routes/restructure.py`：包 `run_restructure_stream`（referee-skipped）。
- [ ] 3.3 `routes/referees.py`：eval_fn 包现有 `_await_referees`（**2.0s fail-open、开口后时序不变**）；保留「无 task 时返回 []」+ per-referee `asyncio.shield` 契约；`_resolve_transfer_llm` 不动（留 change-3 tool:transfer 收编）。
- [ ] 3.4 `routes/selector.py`：`DeciderAction`→effect-route 映射（transition(goal_achieved)→wrap-up 效果 / transition(transfer)→handoff / transition(customer_decline)→activating / restructure→restructure route / continue→listening）。
- [ ] 3.5 `routes/builder.py`：从 `PipelineConfig`（referees / restructure / routing_rules / primary_referee_label / max_continuous_restructure）构造 Router。
- [ ] 3.6 单测覆盖各 route + selector 映射等价于现行 `decide()` 应用。

## 4. turn_controller（flag-ON 用户轮处理器）

- [ ] 4.1 `turn_controller.py`：复现 run_loop 现有「PROCESSING → `run_pipeline_stream` → play → await referees → `decide` → 施 effect」（≈ run_loop.py 626-908）的等价路径，但决策计算经 Router。
  - NOTE：**effect 执行调用现有 run_loop 函数、一字不改**（design D6，无 sink 参数化、无 dual-writer）；`transition_to` / `_publish_status` 仍同步、仍由原函数发。
  - NOTE：保留 cross-turn 计数器（interruption / restructure / silence / wrap-up）、text≥2 门、greeting 非打断、wrap-up 关 referee / transfer / filler、turn_id 在 `run_pipeline_stream` 同点 bump、play 先于 effect。
- [ ] 4.2 单测：flag-ON 用户轮处理在 mock harness 下与 legacy 内联决策**产出同样 `DeciderAction` + 同样 effect 调用序**（覆盖 goal / transfer / decline / restructure / continue）。

## 5. run_loop 接线 + golden 双跑

- [ ] 5.1 `run_loop`：在**用户轮处理**上据 `ENGINE_USE_ROUTER` 二选一（legacy 内联 vs turn_controller+Router）；**驱动循环 `_await_user_or_silence` + silence/no-progress/remote-hangup 分支 + 状态机 + `_publish_status` + finalize 零改动**；flag-OFF 不实例化 Router/turn_controller。
- [ ] 5.2 `test_golden_transcript.py` 参数化 `ENGINE_USE_ROUTER ∈ {off, on}`；OFF 匹配既有 golden；ON 对 3 确定性场景（one_turn_hangup / goal_achieved_wrapup / silence_activation_hangup）匹配同一 golden（silence 场景天然过：不进 Router）。
- [ ] 5.3 `test_run_session_contract.py` 仍绿（签名 / 枚举不变）。
- [ ] 5.4 **覆盖盲区显式记录**：barge-in / restructure / transfer / listen_only 的 ON 路径逐字节验证 **defer change-3 真机 gate**；生产 flag 保持 OFF。

## 6. 校验 + archive 纪律

- [ ] 6.1 `openspec validate engine-multi-route-dispatch --strict` 通过。
- [ ] 6.2 engine 全套测试绿（含新单测 + golden 双跑）。
- [ ] 6.3 本 change archive 须在写 change-3 ai-pipeline MODIFIED delta **之前**（蓝图 §5）。
