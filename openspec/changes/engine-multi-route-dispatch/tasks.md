## 0. 前置 & 纪律

- [x] 0.1 change-1 `engine-eventbus-foundation` 已 archive（2026-06-06）——满足蓝图 §5。
- [x] 0.2 本 change **纯 ADDED delta、仅碰 ai-pipeline**（SelectRouter 效果分发，Shape B）。不 MODIFY 任何现有 requirement、**不碰 call-state-machine** → 与 active 的 `referee-hangup-action`（MODIFIED decider）/ `call-state-machine-soften-guard`（MODIFIED 状态集合）**零互踩**。projector / FSM→投影 / eager-dialogue-route / live-gen / tool / gating / MODIFIED·REMOVED 全部留 change-3。
- [x] 0.3 engine 多-Edge gRPC WIP（9 文件）已 `git stash`（stash@{0}，change-2 apply 期间 parked）；apply 收尾 `git stash pop`。

## 1. settings flag（默认 OFF）

- [x] 1.1 `settings.py`：加 `engine_use_router: bool = False`（alias `ISALES_ENGINE_USE_ROUTER`），docstring 注明 removal trigger = change-3 Phase-4。flag 经 `load_runtime_config` 拷进 `RuntimeConfig.engine_use_router`（生产从 Settings/env 读；测试用 `_make_config` 直设）——run_session 签名 frozen，不能加参。

## 2. SelectRouter 内核（效果路由表）

- [x] 2.1 `select_router.py`：`ExecutableRoute` 协议（`route_id` / `metadata` / `async execute(ctx) -> Directive`）+ `Directive`(CONTINUE|RETURN|FALL_THROUGH) 枚举 + `Router`（`routes` 表 + `selector`；`dispatch(action, ctx)`：selector 选 route → `await route.execute(ctx)`；selector 返回 None → FALL_THROUGH；**不 catch 异常**保 byte-identity）。loud docstring 标 eager-dialogue/live-gen/tool/gating 是 change-3。
- [x] 2.2 `tests/test_select_router.py`：selector 映射 + dispatch 调对 route + None→FALL_THROUGH + 异常传播（不被吞）。

## 3. effect routes + selector + builder

- [x] 3.1 `routes/effects.py`：4 条 effect-route（`GoalAchievedRoute` / `TransferRoute` / `CustomerDeclineRoute` / `RestructureRoute`），各 `execute(ctx)` 复用现有 run_loop 效果函数**同序同参**、返回 Directive（=840-906）。per-turn 值 + 效果函数引用经 `EffectContext`（dataclass）注入，避免 run_loop import cycle。
- [x] 3.2 `routes/selector.py`：`DeciderAction`→route-id（goal_achieved/transfer/customer_decline→各 route；restructure→RestructureRoute；continue/未匹配/未知 to→None）。
- [x] 3.3 `routes/builder.py`：构造 `Router`（注册 4 route + selector）。
- [x] 3.4 `tests/test_effect_routes.py`：每条 route 在 mock harness 下与 legacy 内联**同序同参 + 同 Directive**（goal / transfer / customer_decline / restructure 的 capped·text·degraded·interrupted 各分支）。

## 4. run_loop 接线 + golden 双跑

- [x] 4.1 `run_loop`：在 839 的 `if not is_wrap_up:` decider 分支加 flag 分叉——OFF=现有内联 if/elif（4 个 `if`→`elif`，零行为改动）；ON=构造 `EffectContext` + `directive = await effect_router.dispatch(action, ctx)` + 据 directive `return`/`continue`/落 cap-reset。**驱动循环 / play / referees / decide / wrap-up / 908 cap-reset / 937 tail / 状态机 / finalize 零改动**；OFF 不实例化 Router。`use_router = config.engine_use_router`（顶部读一次）。
- [x] 4.2 `test_golden_transcript.py` 参数化 `ENGINE_USE_ROUTER ∈ {off, on}`；OFF 匹配既有 golden；ON 对 3 确定性场景匹配同一 golden（goal_achieved_wrapup 走 GoalAchievedRoute；one_turn_hangup / silence 不经 effect-route）。**6 例全绿——byte-identity 成立**。
- [x] 4.3 `test_run_session_contract.py` 仍绿（签名 / 枚举不变）。全套 **349 passed / 27 skipped**。
- [x] 4.4 **覆盖盲区显式记录**：transfer / customer_decline / restructure effect-route 的真机逐字节 **defer change-3 真机 gate**（golden 不覆盖，靠 3.4 单测）；生产 flag 保持 OFF。

## 5. 校验 + 收尾

- [x] 5.1 `openspec validate engine-multi-route-dispatch --strict` 通过。
- [x] 5.2 engine 全套测试绿（349 passed / 27 skipped，含新单测 + golden 双跑 + ruff 净）；`git stash pop` 复原多-Edge WIP。
- [ ] 5.3 本 change archive 须在写 change-3 ai-pipeline MODIFIED delta **之前**（蓝图 §5）。【留待 /opsx:archive】
