## 1. 会话状态：新增「回合进行中」标记位

- [x] 1.1 `isales-engine/isales_engine/call_session.py`：新增 `in_processing_turn: bool = False`（紧邻 `interruption_signaled`），docstring 注明：THINKING + 播音整段为真、LISTENING 为假，供 `_partial_monitor` 守卫识别"本轮回复正在进行"，仅扩覆盖、非新机制。

## 2. 扩大 `_partial_monitor` 生效范围（判定核不变）

- [x] 2.1 `run_loop.py` `_partial_monitor`：守卫改为 `if (not session.in_processing_turn and session.current_speaking_task is None) or session.interruption_signaled: continue`（严格叠加：本轮在进行 **或** 正在播音才求值；LISTENING 仍不触发）。
- [x] 2.2 `evaluate_partial` 调用与规则树不变（同阈值/白名单）；触发动作（置 `interruption_signaled` + 记 `interruption` 事件 + `cancel(current_speaking_task)`）不变——思考窗口下 `current_speaking_task` 为 None，cancel 自然 no-op；abort 由 `_run_gated_turn` 据信号驱动（§3）。monitor 仍是信号单写者，未碰候选。
- [x] 2.3 更新 docstring 为「watch ASR partials during SPEAKING / FILLER / PROCESSING-pre-audio（THINKING）」，并注明守卫放宽 + LISTENING 不触发不变式。

## 3. `_run_gated_turn`：标记回合 + 思考阶段响应 `interruption_signaled`

- [x] 3.1 `_run_gated_turn`：在 wrap-up 早返回**之后**、spawn 候选**之前**置 `session.in_processing_turn = True`，用 `try/finally` 把「spawn 候选 + 门控 await」包住，门控一返回（或抛异常）即在 finally 清 `False`。lifetime = THINKING 窗口 [entry→gate-resolve]；wrap-up 走 `_gated_wrap_up_turn`、不置位（已知缺口，不在本 change 范围）。
- [x] 3.2 门控 await 之后立即检查 `interruption_signaled`（check#1）：monitor 在门控 await 期间已把信号置位，await 返回后随即观察即可——**无需 Event / 无需 race**（无音频播出，等门控走完再 abort 不会让客户听到错音频）。
- [x] 3.3 [gate-resolve→首音频] 尾窗：`in_processing_turn` 在门控 finally 即清零，该尾窗由**现有播音 barge-in** 覆盖（A 一开播 `current_speaking_task` 置位、monitor 照常取消）——故**无需改 `_play_streaming`**、无 check#2。实现比原设想更省。
- [x] 3.4 check#1 abort 分支：`await _cancel_candidates()`（取消 main + persona eager，复用 `cancel_eager` 释放连接）；`session.interruption_signaled = False`；`session.consecutive_interruption_count += 1`；落一条 `_base_trace(..., first_audio_ms=None)`+referee_results 的 trace；`return Directive.CONTINUE`。未写 `interrupt_remaining_text`（保持 None）。

## 4. 复用既有 coalesce + main 管线重答（不丢 A、不进 restructure）

- [x] 4.1 abort 返回后主循环 `_await_user_or_silence` 既有 coalesce 把排队的 B 合并为下轮 `user_text`；A 已在 `dialog_history`（`user_speech` 镜像，`call_session.py:242-243`），`build_main_messages` 天然带入——无 requeue、无改 `dialog_history`。（集成测断言 A 仍是 user 轮。）
- [x] 4.2 思考窗口 abort 路径下 `session.interrupt_remaining_text` 恒 None（仅 `_play_streaming` finally 在已开播被砍时写），decider restructure 改判被跳过——恒走 main 管线"新回答"。（集成测断言 `interrupt_remaining_text is None`。）

## 5. 测试（`tests/test_realtime_interruption.py`）

- [x] 5.1 守卫单测：`test_partial_monitor_triggers_in_thinking_window`（思考窗口实质 partial → `triggered`）+ `test_partial_monitor_ignored_in_listening_no_turn`（LISTENING 不触发）。
- [x] 5.2 `test_partial_monitor_thinking_window_whitelist_ignored`：思考窗口白名单语气词仍 `ignored`（与 SPEAKING 同标准）。
- [x] 5.3 `test_thinking_window_second_utterance_aborts_turn` 集成测：门控 stall 拉宽 THINKING，注入带真实 wall-clock 间隔的第二句 partial（feed_turn 是 burst、`partial_step_ms` 只填 timestamp 字段不产生真实延时，故直接 `asr._queue.put` + `sleep`）→ 记 `interruption` 事件、落 `first_audio_ms=None` trace、A 仍在 `dialog_history`、`interrupt_remaining_text is None`。
- [x] 5.4 零回归：全量 `pytest -q` = 467 passed / 22 skipped / 1 failed（`test_gate_fails_open_to_main_on_referee_timeout` 在**改前的干净树上也失败**，与本 change 无关）。
- [x] 5.5 连续打断保护：abort 走 `consecutive_interruption_count += 1`（与播音 barge-in 同一计数器），`_decide_protection` 的 `short_reply` / `listen_only` 阶梯已有专项单测（`test_decide_protection_*`）——经组合覆盖，未另写多次-abort 的时序脆弱集成测。
- [x] 5.6 `.venv/bin/python -m pytest -q` 全绿（除上述既有失败）。

## 6. 校验 + 部署 + 实呼 smoke

- [x] 6.1 `make spec-validate`（含 `openspec validate --strict`）通过。
- [x] 6.2 已部署 ECS `121.89.85.150`（2026-06-20 09:57 CST）：preflight md5==git base `59b2fae`（无漂移）→ 备份 `*-thinking-window` → scp 2 文件 + chown（post-scp md5==git HEAD `5709d2e`）→ 重启 engine（active、clean boot、`in_processing_turn` 在两文件、他方 hotspot 改动仍在）。详见 `deploy/cloud/STATE.md` 顶条。commit meta `f90d66f`。
- [ ] 6.3 实呼 smoke（**DEFERRED — 用户决定提前 archive，真机验收待补**）：复现「客户说 A → 停顿（AI 未出声）→ 说 B」确认不再慢一拍、语气词不误打断、播音中 barge-in→重组不回归。代码已上线、单测全覆盖；此项是行为层的真机确认，需人工拨测，归档后单独补做（不通过则按 STATE.md 顶条 rollback）。
- [x] 6.4 根文档漂移核查：grep 根 docs（`DESIGN.md` / `IMPLEMENTATION_PLAN.md` / `README.md`）无「barge-in 仅限 SPEAKING/FILLER」的摘要陈述；spec 索引指向 capability spec 本身，已随 delta 更新——无需额外根文档改动。
