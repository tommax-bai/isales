## ADDED Requirements

### Requirement: SelectRouter 多路分发（kill-switch ENGINE_USE_ROUTER）

engine SHALL 提供一个 `SelectRouter`，把每轮用户对话的**决策计算**（跑 referees + 选下一步）从 `_main_turn_loop` 的内联 if/elif 抽出，作为其**替身路径**，由 settings `ENGINE_USE_ROUTER` 门控。`ENGINE_USE_ROUTER` 默认 **OFF**——OFF 时 engine MUST 走现有内联决策，行为**逐字节不变**（change-0 golden-transcript 网兜底）。本 Requirement 是扁平化重构的骨架步；**MUST NOT 引入任何生产行为变化**——referee 开口前 gating、eager 多人设（N>1）、挂断 / 转人工 tool route、`StatusProjector` / 状态机投影改写**全部属 change-3**。

本 change 的 Router 是 N=1 对话 route 的退化形态，且保留 iSales **开口后**（post-reply）referee 时序（非 voxen 的 eval-before-gather）。kill-switch + 双路径是 removal-tracked 过渡债：**removal trigger = change-3 Phase-4** 删除 legacy 决策块 + `ENGINE_USE_ROUTER` flag 的同一 commit。

#### Scenario: kill-switch 默认 OFF 逐字节不变

- **WHEN** `ENGINE_USE_ROUTER` 未设置或为 OFF
- **THEN** engine MUST 走现有内联决策路径，MUST NOT 把 Router / turn_controller 实例化到主路径
- **AND** full_transcript + pipeline_trace MUST 与 change-0 golden 逐字节一致

#### Scenario: Router 编排顺序（flag ON，保留开口后 referee）

- **WHEN** `ENGINE_USE_ROUTER` ON 且一轮用户 final 经驱动循环到达 PROCESSING
- **THEN** `turn_controller` 经 Router SHALL 依次：① eager 启动 1 条对话 route → ② **先播放**该回复（复用 `_play_streaming`）→ ③ **开口后**以 referees 为 `eval_fn` 取结果 → ④ 用 `decide()`（原样复用、first-match-wins 不变）作 selector 选下一步 effect-route → ⑤ 经现有 run_loop 函数施 effect
- **AND** Router MUST NOT 套用 voxen 的 eval-before-gather（开口前判）顺序——referee 时序与现行一致（开口后 await、每-referee `asyncio.shield` + 2.0s fail-open）；开口前 gating + 2.0s→~600ms 收紧属 change-3，本 change MUST NOT 改

#### Scenario: 对话 route 交出 started PipelineStream（eager-generator deviation）

- **WHEN** 对话 route 被 eager 启动
- **THEN** route 的 `execute` MUST 返回 **已 `start()` 的 `PipelineStream`**（main + referees 已 spawn、`current_turn_id` 已 bump），但 **`sentences()` 尚未被迭代**——下游 `_play_streaming` MUST 仍是 `sentences()` 的唯一消费者，MUST NOT 在 Router 内部迭代 / 收集生成器
- **AND** engine MUST 有回归测试断言 Router 返回时 `sentences()` 未被迭代——一旦在 Router 内排空它，每轮回复将哑火（首音频延迟暴涨、打断无法中途取消、逐句计时坍塌）

#### Scenario: decide() 原样复用为 selector

- **WHEN** referees（eval_fn）返回 N 个 category
- **THEN** Router 的 selector MUST 调用现有 `decide(referee_results, routing_rules, ...)`（body 不改、first-match-wins 不改），并把其 `DeciderAction`（transition / restructure / continue）映射到对应 effect-route
- **AND** 现有 campaign 的 `routing_rules`（无 persona / tool 配置）MUST 命中与现行完全相同的分支——决策结果 MUST NOT 改变

#### Scenario: effects + 驱动循环 + 状态机 verbatim

- **WHEN** Router 产出选中的 effect-route
- **THEN** engine SHALL 调用**现有 run_loop 函数**施加 effect（`transition_to` / `_perform_handoff` / restructure 执行 / `default_reply` 兜底 / `_play_streaming`），这些函数**一字不改**、仍同步调 `transition_to` / `_publish_status`——本 change MUST NOT 引入 `StatusProjector`、MUST NOT 改状态机或 `_publish_status`
- **AND** 驱动循环 `_await_user_or_silence`（含 final-coalescing）+ silence / no-progress / remote-hangup 结局分支 MUST verbatim（这些结局根本不进 Router）
- **AND** must-not-drop 机制 MUST 原样保留：`_play_streaming` / `_SynthJob` 预合成（maxsize=2）、`_assemble_interrupt_text`、cross-turn 计数器、greeting 非打断顺序、text≥2 门、wrap-up 关 referee、the ONE `chat_stream→chat` fallback + `default_reply` guard、shielded finalize + DECR snap-to-0、post-call extractor 走线下 finalize、每个终结路径设 `session.hangup_cause`（均由复用原函数继承）

#### Scenario: golden net 双 flag 验证 + 硬件路径 defer

- **WHEN** 验收本 change
- **THEN** golden-transcript 网 MUST 在 `ENGINE_USE_ROUTER` OFF 与 ON 两态各跑一遍；OFF MUST 匹配既有 golden；ON MUST 对 3 个确定性场景（one_turn_hangup / goal_achieved_wrapup / silence_activation_hangup）匹配同一 golden
- **AND** barge-in / restructure / transfer / listen_only 的 ON 路径逐字节验证 MUST 延后到 change-3 真机 UX gate（golden 不覆盖、需物理 SIM7600 rig）；在此之前生产 `ENGINE_USE_ROUTER` MUST 保持 OFF
