## Why

通话中存在一类「对话永远慢一拍」的错乱：客户说完第一句 A、短暂停顿，在 AI 还没出声（已收到 A 的 ASR final、main LLM 正在生成、首个 TTS 音频尚未释放——下称**思考窗口 / PROCESSING-pre-audio**）时又说了第二句 B。今天的 barge-in 判定被**硬绑在"正在播音"**上：`_partial_monitor` 的死区守卫 `if session.current_speaking_task is None or session.interruption_signaled: continue`（`run_loop.py:2079`）在思考窗口里把 B 的所有 ASR partial 当状态更新丢弃，规则树根本不求值；B 的 final 只是排进 `asr_finals_q` 等下一轮被当成**独立的下一回合**处理。于是引擎本轮答 A、下轮才捞到 B（此时客户已说了 C），每一句 AI 回复都落在已被客户超越的那句话上——永久滞后。

根因不是"判定逻辑不对"，而是**打断的覆盖范围太窄**：barge-in 只覆盖 SPEAKING/FILLER，漏掉了同样属于"AI 这一轮回复正在进行"的思考窗口。

## What Changes

**核心约束（来自用户）：复用现有 barge-in 机制，不新增任何检测机制，只扩大打断的生效范围。**

- **扩大 `_partial_monitor` 的生效范围**：判定条件从「音频正在播」（`current_speaking_task` 存在）放宽为「本轮回复正在进行」（思考窗口 **或** 播音）。判定核**逐字节复用**同一棵 `evaluate_partial` 规则树（同样的 `interruption_min_chars` / `duration` / 白名单），思考窗口里对"嗯/好的"等语气词的忽略标准与播音时**完全一致**。
- **让思考阶段响应既有的 `interruption_signaled` 信号**：`_run_gated_turn` 在释放任何音频之前的等待段（`_await_referees` 门控 + eager 缓冲），在 B 触发打断时复用现有 `_cancel_candidates` / `cancel_eager` 取消在飞的对话候选，回主循环；主循环既有的 final coalesce（`run_loop.py:955-974`）把 A+B 合并成一条输入，**经 main 管线（裁判门完整保留）重新生成一条覆盖 A+B 的回复**。
- **思考窗口的打断 NOT 触发重组**：因为一个字都没播出，没有"被打断的半句"可续——MUST NOT 写 `interrupt_remaining_text`、MUST NOT 走 restructure（现有的播音中被打断→重组路径**逐字节不变**）。
- **连续打断保护一致计数**：思考窗口的打断 abort 与播音中 barge-in 一样递增 `consecutive_interruption_count`，沿用既有 `short_reply` / `listen_only` 阶梯。
- **最小新增**：仅一个"当前正处于回复回合"的会话标记位（与既有 `current_speaking_task` / `in_wrap_up` 同类的状态位，非新检测逻辑），供放宽后的守卫识别思考窗口。

**明确不做（已逐项排除）**：不加 final 级 watcher；不加 MERGE 裁判类别；不改 restructure 输入契约；不复用/不喂已生成的草稿；不动 isales-common / web / alembic。

## Capabilities

### New Capabilities
<!-- 无新增 capability：仅扩大既有 barge-in 判定的生效范围。 -->

### Modified Capabilities

- `interruption-detection`: `可组合规则树打断判定` Requirement 当前把 barge-in 入口范围限定为「SPEAKING / FILLER 状态下」——扩大到同时覆盖 **PROCESSING 思考窗口（首音频释放前的生成阶段）**；判定核（规则树 / 阈值 / 白名单）不变，仅扩大 `_partial_monitor` 生效阶段。`连续打断保护` 同步覆盖思考窗口的打断。
- `ai-pipeline`: `AI 管线编排` 新增思考窗口被打断的门控行为——当 barge-in 在门控/生成阶段（首音频释放前）触发时，engine SHALL 取消全部 eager 对话候选、MUST NOT 释放本轮（A 的）回复、SHALL 把待处理用户句合并后经 main 管线重新门控生成；该窗口 MUST NOT 捕获 `interrupt_remaining_text`、MUST NOT 进入 restructure。

## Impact

- **代码**：`isales-engine/isales_engine/run_loop.py`（`_partial_monitor` 守卫 + `_run_gated_turn` 思考段响应 `interruption_signaled` + abort/coalesce）、`isales-engine/isales_engine/call_session.py`（新增「回合进行中」标记位）。
- **无改动**：isales-common（无 schema / 无新 campaign 列——判定复用既有 `interruption_*` 配置）、isales-api、isales-web、alembic。
- **行为**：思考窗口里客户的实质性第二句会**立刻打断**未出声的本轮，A+B 合并经 main 管线（裁判门完整）一次答清——消除"慢一拍"。语气词/超短句按既有规则树仍被忽略。播音中被打断→重组、FILLER/WRAPPING_UP 交互、单句正常回合：行为不变。
- **延迟**：常见的"无第二句"回合**零额外开销**（守卫只是放宽，未引入新等待）；仅当客户真在思考窗口插话时才付出取消 + 重生成的代价（与播音中 barge-in 的浪费同档、自限于连续打断保护）。
- **部署**：scp engine 两个文件 + 重启 engine；无迁移。
- **验证**：死区是时序现象，单测覆盖守卫放宽 + abort/coalesce 分支后，真实"慢一拍"修复 MUST 经 cloud/edge 实呼 smoke 确认（见 `deploy/cloud/STATE.md`）。
