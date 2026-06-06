## ADDED Requirements

### Requirement: SelectRouter 效果分发（kill-switch ENGINE_USE_ROUTER）

engine SHALL 提供一个 `SelectRouter`，把每轮用户对话 **`decide()` 之后的「下一步效果分发」**（goal_achieved → 收尾 / transfer → 转人工 / customer_decline → 激活 / restructure → 重组）从 `_main_turn_loop` 的内联 if/elif（run_loop.py 838-906）抽成一张**效果路由表**，由 settings `ENGINE_USE_ROUTER` 门控。`ENGINE_USE_ROUTER` 默认 **OFF**——OFF 时 engine MUST 走现有内联效果分发，行为**逐字节不变**（change-0 golden-transcript 网兜底）。

本 change 是扁平化重构的骨架步；**MUST NOT 引入任何生产行为变化**。明确**留 inline、不进 Router**（保持 verbatim）：对话生成（`run_pipeline_stream`）、播放（`_play_streaming`）、**开口后** referees（`_await_referees`）、`decide()`、final-coalescing、wrap-up 处理（910-935）、restructure-cap-reset（908）、收尾 LISTENING tail（937）。eager 多人设对话 route（N>1）+ live-generator deviation + 挂断/转人工 tool route + 开口前 gating + `StatusProjector` 全部属 **change-3**。

kill-switch + 双路径是 removal-tracked 过渡债：**removal trigger = change-3 Phase-4** 删除 legacy 内联效果分发 + `ENGINE_USE_ROUTER` flag 的同一 commit。

#### Scenario: kill-switch 默认 OFF 逐字节不变

- **WHEN** `ENGINE_USE_ROUTER` 未设置或为 OFF
- **THEN** engine MUST 走现有内联效果分发，MUST NOT 把 Router 实例化到主路径
- **AND** full_transcript + pipeline_trace MUST 与 change-0 golden 逐字节一致

#### Scenario: 效果分发经路由表（flag ON）

- **WHEN** `ENGINE_USE_ROUTER` ON 且某轮（非 wrap-up）`decide()` 产出 `DeciderAction`
- **THEN** engine SHALL 经 selector 把该 `DeciderAction` 映射到一条 effect-route，并 `await route.execute(ctx)`；route 内部 MUST 调用**现有 run_loop 效果函数**（`sm.transition_to` / `_perform_handoff` / `_run_restructure` / `_play_tts` / `session.append_event`）以**同样的顺序、同样的参数**施加效果
- **AND** route MUST 返回一个控制指令（continue / return / fall-through），turn_controller 据此 `continue` 当前循环、`return` 结束通话、或落到共享的收尾 LISTENING tail——与 legacy `continue` / `return` / 落到 937 的控制流逐字节等价

#### Scenario: decide() 与对话/referees 保持 inline verbatim

- **WHEN** flag ON 处理一轮用户对话
- **THEN** `run_pipeline_stream` → `_play_streaming` → **开口后** `_await_referees` → `decide()` MUST 仍内联在 run_loop、一字不改（first-match-wins 不变、2.0s fail-open 不变、post-reply 时序不变）
- **AND** 现有 campaign 的 `routing_rules`（无 persona / tool 配置）MUST 命中与现行完全相同的分支——决策结果 MUST NOT 改变

#### Scenario: 共享 inline tail + must-not-drop verbatim

- **WHEN** flag ON 某轮 `decide()` 产出 continue / 降级（无匹配 route）或 wrap-up 轮
- **THEN** engine SHALL 落到**共享的内联收尾**（restructure-cap-reset 908 / wrap-up 处理 910-935 / `sm.transition_to(LISTENING, "tts_done")` 937），这些 MUST NOT 进 Router、MUST verbatim
- **AND** must-not-drop 机制 MUST 原样保留（均由复用原函数/原 inline 继承）：`_play_streaming` / `_SynthJob` 预合成（maxsize=2）、`_assemble_interrupt_text`、cross-turn 计数器、greeting 非打断顺序、text≥2 门、wrap-up 关 referee、the ONE `chat_stream→chat` fallback + `default_reply` guard、shielded finalize + DECR snap-to-0、post-call extractor 走线下 finalize、每个终结路径设 `session.hangup_cause`

#### Scenario: golden net 双 flag 验证 + 硬件路径 defer

- **WHEN** 验收本 change
- **THEN** golden-transcript 网 MUST 在 `ENGINE_USE_ROUTER` OFF 与 ON 两态各跑一遍；OFF MUST 匹配既有 golden；ON MUST 对 3 个确定性场景（one_turn_hangup / goal_achieved_wrapup / silence_activation_hangup）匹配同一 golden
- **AND** golden 覆盖盲区（goal_achieved_wrapup 覆盖 goal→wrap-up→END 效果路由；one_turn_hangup 覆盖 user-hangup；silence 不进用户轮）外，transfer / customer_decline / restructure effect-route 的 ON 路径 MUST 由**新增单测**覆盖（mock harness 断言与 legacy 内联同序同参），其真机逐字节 defer 到 change-3 真机 UX gate；在此之前生产 `ENGINE_USE_ROUTER` MUST 保持 OFF
