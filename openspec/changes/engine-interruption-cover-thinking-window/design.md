## Context

引擎的 barge-in 判定今天**唯一**入口是 `_partial_monitor`（`run_loop.py`），它对每个 ASR partial 跑一棵可组合规则树（`evaluate_partial`）。但它的第一行守卫是：

```python
if session.current_speaking_task is None or session.interruption_signaled:
    # Not in SPEAKING / FILLER — partials are just status updates.
    continue
```

`session.current_speaking_task` **只**在 `_play_chunks` 真正开始推音频时被赋值（`run_loop.py:2022-2023`）、播完清空（2032-2033）。因此一整个**思考窗口**——从 `_run_gated_turn` 入口经 `_await_referees` 门控（~600ms）+ eager 缓冲 + LLM/TTS TTFT，直到首个 PCM chunk（常 1-3s）——`current_speaking_task is None`，规则树**根本不求值**。客户在此窗口说的第二句 B：partial 被守卫丢弃，final 排进 `asr_finals_q` 干等，主循环正卡在 `_run_gated_turn` 里读不到它。等本轮（答 A）播完回到 `_await_user_or_silence`，才把 B 当**下一回合**捞出来——此时客户已说了 C。每轮 AI 回复都落在已被超越的那句上，永久滞后（详见 proposal § Why + 已存档诊断）。

`_run_gated_turn` 是 gate-first 单回合：spawn eager 候选（main + 可选 persona）→ `await _await_referees`（门控）→ `decide()` 选路 → `_play_streaming` 释放音频。播音中被打断→捕获 `interrupt_remaining_text`→（可选）restructure 的链路（`run_loop.py:1188-1228, 1507-1529, 239 spec`）**只**对已开播的回合有意义，思考窗口够不到它。

`user_speech` 事件经 `append_event` **已镜像进 `dialog_history`**（`call_session.py:242-243`），所以 A 在进入 `_run_gated_turn` 前就已是一条 user 轮次。

## Goals / Non-Goals

**Goals:**

- 把 barge-in 的生效范围从「SPEAKING/FILLER（正在播音）」**扩大**到「本轮回复正在进行（思考窗口 + 播音）」，消除思考窗口死区。
- 判定核**逐字节复用**现有 `evaluate_partial` 规则树（阈值/白名单/不可撤销策略全不变）——思考窗口与播音窗口对"嗯/好的"的忽略标准一致。
- 思考窗口被打断时：取消未出声的本轮、合并客户句、经 **main 管线（裁判门完整）** 重新生成一条回复；常见的"无第二句"回合零额外开销。

**Non-Goals:**

- 不新增任何检测机制（无 final 级 watcher、无 VAD 触发、无第二分类器）。
- 不加 MERGE 裁判类别、不改 restructure 输入契约、不复用已生成草稿。
- 思考窗口**不**做 restructure / 不捕获 `interrupt_remaining_text`（一字未播，无半句可续）。
- 不覆盖 wrap-up 生成窗口（`_gated_wrap_up_turn` 无候选 fan-out）——记为已知 v1 缺口。
- 不动 isales-common / api / web / alembic（判定复用既有 `interruption_*` campaign 列，无新列）。

## Decisions

### D1：用一个「回合进行中」标记位放宽守卫，而非删守卫 / 加 turn_phase 枚举

新增 `session.in_processing_turn: bool`（与既有 `current_speaking_task` / `in_wrap_up` 同类的会话状态位，**非**新检测逻辑）。`_run_gated_turn` 入口（spawn 候选前）置 `True`，回合退出的 `finally` 置 `False`——覆盖思考 + 播音 + filler 整段。守卫改为**严格叠加**，只增不减现有行为：

```python
if (not session.in_processing_turn and session.current_speaking_task is None) \
        or session.interruption_signaled:
    continue
```

即「本轮在进行 **或** 正在播音」才求值规则树。现有 SPEAKING/FILLER 触发（`current_speaking_task` 已置）逐字节保留；LISTENING（`in_processing_turn=False` 且无播音）仍不触发——`_await_user_or_silence` 等首句 A 时不会被规则树误判。

- **备选：直接删 `current_speaking_task is None`**——会让 LISTENING 期间首句 A 的 partial 也触发"打断"（无回合可打断、却置 `interruption_signaled` 泄漏到下轮），错误。否决。
- **备选：引入 `turn_phase{LISTENING,THINKING,SPEAKING}` 枚举**（原 Angle C 重型版）——能力等价但属"新机制/新状态模型"，超出"只扩覆盖范围"的约束。一个 bool 足够，否决枚举。

### D2：思考阶段在既有 await 点观察同一个 `interruption_signaled` 而 abort——一个信号贯穿两阶段

`_partial_monitor` 触发动作**不变**：置 `session.interruption_signaled = True` + 记 `interruption` 事件 + `cancel(current_speaking_task)`（思考窗口该任务为 None，自然 no-op）。**信号是跨阶段的唯一载体**，monitor 保持单一写者，候选的拆除归 `_run_gated_turn`（与"StateMachine 是唯一状态写者"同纪律）。

`_run_gated_turn` 把首音频释放前**仅有的两个 await 边界**改为响应该信号：

1. 门控等待 `await _await_referees(...)` 与 `interruption_signaled` 竞速（`asyncio.wait(FIRST_COMPLETED)`）；信号先到 → abort。
2. `_play_streaming` 释放首个 chunk 前检查 `interruption_signaled`；置位 → abort。一旦 chunk 开始流动（`_play_chunks` 置 `current_speaking_task`），交回**现有播音 barge-in 取消路径**接管。

两个检查点读的是**同一个**既有 flag，覆盖整个 [门控→首音频] 窗口（含 LLM/TTS TTFT 这段 `current_speaking_task` 仍为 None 的子窗），不是两套机制。abort 动作复用既有 `_cancel_candidates()` / `cancel_eager()`（`orchestrator.py:347`）拆除全部 eager 候选 + 取消门控 referee 任务（释放 vendor 连接，同播音 barge-in 的 finally 已做的拆除），随后 `return Directive.CONTINUE`。

- **备选：仅门控后单点检查**——漏掉 [门控resolve→首音频] 子窗（常 1-3s，`current_speaking_task` 仍 None），B 落此窗仍滞后。否决。
- **备选：把思考工作做成 session 上的可取消任务、由 monitor 直接 cancel**——更贴近"播音 cancel"对称，但候选当前是 `_run_gated_turn` 局部、上移到 session 改动更大、且双写者（monitor+turn 都碰候选）易出 ordering bug。用"信号 + turn 自己拆"更小且单写者。

### D3：abort 后走 main 管线答 B（A 已在 history），思考窗口恒「新回答」、永不 restructure

abort 返回主循环 → `_await_user_or_silence` 把 `asr_finals_q` 里排队的 B（及更晚的 C）经**既有 coalesce**（`run_loop.py:955-974`）合并 → 主循环正常起一轮 `_run_gated_turn(user_text=B)`，经 **main 管线 + 完整裁判门**生成回复。**A 不丢**：它已在 `dialog_history`（D-Context），`build_main_messages` 把它作为前序 user 轮带入，回复天然覆盖「A（上下文）+ B（最新）」。

重组 vs 新回答**结构化、零运行时分支**：decider 的 restructure 改判（ai-pipeline §被打断自动重组开关）以 `session.interrupt_remaining_text` 非空为前提，而该字段**只**由 `_play_streaming` 的 finally 在已开播被砍时写（`run_loop.py:1228`）。思考窗口一字未播 → 字段恒空 → restructure 改判**可证地被跳过** → 走 main 管线新回答。播音中被打断→重组那条路**逐字节不变**。结论：「重组 ⇔ 有被捕获的余句 ⇔ 已开播」「新回答(A+B) ⇔ 无余句 ⇔ 思考窗口」由既有信号位置自动编码，本 change 不加任何"选哪个"分支。

abort 的本轮（A）SHALL 写一条 `pipeline_trace`（复用 `_gated_trace`，`interrupted=True`、`first_audio_ms=None`），与播音 barge-in 的 trace 对齐，便于分析看到"思考窗口被打断"。

### D4：连续打断保护一致计数

思考窗口 abort SHALL `session.consecutive_interruption_count += 1`（镜像播音 barge-in 的 `run_loop.py:1679-1680`），使 `short_reply` / `listen_only` 阶梯把思考窗口打断与播音打断同等计数——客户连续抢话同样触发保护，无需新阈值。

## Risks / Trade-offs

- **[连续两条同 role user 轮（user:A, user:B）]** → abort 不动 `dialog_history`，A 留作前序 user 轮、B 作最新 user 轮，`build_main_messages` 产出两条相邻 user message。引擎在用的 OpenAI-compatible vendor（doubao / qwen / deepseek）容忍相邻同 role message；**Mitigation**：若将来接入严格交替的 provider，再在 `build_main_messages` 合并相邻同 role 轮（一行、可后置，v1 vendor 不需要）。与既有 out-paces coalesce（合成单条 "A B" 轮）的细微差异为可接受发散——两者都覆盖 A+B、都消除滞后。
- **[`asr_finals_q` 消费/顺序竞态]** → 思考窗口里主循环停在 `_run_gated_turn`、**不**在 `_await_user_or_silence` 读队列，故门控竞速期 B 的 final 仍安稳排队、abort 后由既有 coalesce 唯一消费。**Mitigation**：门控竞速胜出（正常无 B 路径）时 MUST 干净取消那个 `interruption_signaled` 等待者，且 monitor 只置 flag、不碰候选——保持单写者，杜绝 double-consume。
- **[vendor 把 A 的尾音/换气重切成新 partial 误触发]** → 复用既有规则树的 `interruption_min_chars`（默认 2）/ duration / 白名单挡掉语气词与超短片段，标准与播音窗口一致；边界 2-3 字真片段仍可能多花一次取消+重生成。**Mitigation**：沿用既有 `interruption_*` 调参，不新增旋钮。
- **[abort 浪费已生成 token / TTS]** → 取消已起跑的 eager 候选丢弃其产出，与播音 barge-in 的浪费同档，仅在客户真在 <~1-3s 内抢话时发生，受连续打断保护自限。
- **[wrap-up 生成窗口未覆盖]** → `_gated_wrap_up_turn` 无候选 fan-out、不在本 change 范围，wrap-up 思考窗口的第二句仍滞后一轮。记为已知 v1 缺口，后续 change 按同模式扩展。
- **[死区是时序现象，单测难全证]** → 单测覆盖守卫放宽 + 门控竞速 abort + coalesce 分支 + 计数；真实"慢一拍"修复 MUST 经 cloud/edge 实呼 smoke（`deploy/cloud/STATE.md`）确认后才算闭环。

## Migration Plan

- 纯 engine 改动，无 DB / 无 alembic / 无 common 版本 bump。
- 部署：`scp` `run_loop.py` + `call_session.py` 到 ECS engine release，重启 engine（按 `deploy/cloud/STATE.md` 流程）。
- 回滚：`git revert` 本 change 两文件、重启 engine 即恢复（守卫与 `_run_gated_turn` 回到原行为；新增的 `in_processing_turn` 不被任何持久化引用）。

## Open Questions

- 无阻塞性未决项。两条相邻 user 轮 vs 合并单轮（见 Risks 首条）按 v1 vendor 容忍取「不动 history」方案，若 smoke 期发现 provider 报错再启用 `build_main_messages` 合并（已规划、不进 v1 范围）。
