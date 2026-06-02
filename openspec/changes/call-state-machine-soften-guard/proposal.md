## Why

iSales call state machine 当前对 `LEGAL_TRANSITIONS` 表外的 transition **抛 `IllegalTransition` 强制阻塞**。但通话场景本质上是并发事件流（user 说话 / AI 说话 / VAD / silence timer / 网络抖动同时到达），严格的"一个时刻一个状态、状态间清晰切换"假设跟现实不匹配。

历史上**反复踩到这种不匹配**——`0c75805` (2026-05-27) 把 ASR + partial_monitor 改到 greeting 之前启动绕开 SPEAKING 不能 process user input；`550902d` / `fa413b1` (2026-05-28) 双次给 INTERRUPTED 进入条件加防护；**2026-06-02 真 mic 测试又踩到 `IllegalTransition: interrupted → activating (reason=silence_threshold)` 让 `run_loop.py:419` crash → engine 异常 hangup_cause=no_progress_timeout**。模式很清晰：每次都加一个 LEGAL_TRANSITIONS 表条目 / 防护补丁，但根因是 strict guard 设计模型本身不 fit。

把 transition guard 从**业务流程 enforcer** 软化为 **advisory tracker**：非法 transition 改为 `logger.warning` + transcript `state_warning` event，**但 transition 仍然执行**。`session.state` 字段、调用代码、call_record schema、跨服务 message contract 全部不动 —— 只改 `transition_to` 内部 ~10 行。

## What Changes

- **`state_machine.py::transition_to`**: 默认行为从"非法 transition → `raise IllegalTransition`"改为"非法 transition → `logger.warning("state_transition_unusual ...")` + 写 transcript `state_warning` event + **继续执行 transition**"。
- **transcript event 名**: `state_error` 改为 `state_warning`（语义降级：advisory 警告而非业务错误）。
- **`force=True` 参数保留**: 现在不再必要（默认就不阻塞），但保留作 backward-compat，避免改动 22 处现有调用方。
- **`LEGAL_TRANSITIONS` 表保留**: 不再做强制 enforcement，**继续作业务流程参考文档**——用于 warning 日志区分"unusual (不在表里)" vs "expected (在表里)" transition。
- **`IllegalTransition` 异常类保留**: 不再被 `transition_to` 抛出，但类定义留作 followup 清理的占位，避免本次 change 跨太多文件。4 处现有 handler 变 dead code，followup change 清理。
- **不改的部分**（保留现有契约）:
  - `session.state` 字段 + `CallStatus` enum (28 处引用) 不动
  - `transition_to` 22 处调用方写法不动
  - call_record `status` 字段 schema 不动（scheduler / worker / web 跨服务消费完全不影响）
  - 数据库 migration 不需要

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `call-state-machine`: 修改 § "状态集合" 末段说明 strict→advisory 转变；**新增** § "非法 transition advisory warning，不阻塞业务流程" Requirement；§ "hangup_cause 单一来源" 里相关 `state_error` event 名改为 `state_warning`。其他 6 个 Requirement (关键状态转换 / 连续打断保护 / FILLER 并行 / WRAPPING_UP / TRANSFERRING / 硬件 URC) 内容不变。

## Impact

**受影响代码**:
- `isales-engine/isales_engine/state_machine.py` (~10 行内部改 `transition_to` 行为 + 改 event 名)
- `isales-engine/tests/test_state_machine.py` (188 行) — 删 / 改写测 IllegalTransition raise 的 testcase 为测 warning log + state 实际改变
- `isales-engine/tests/test_event_pubsub.py` — 检查是否引用 IllegalTransition，可能需小改

**不受影响代码**（保持现状不动）:
- `isales_engine/run_loop.py` 22 处 transition_to 调用（写法不变）
- `isales_engine/realtime/rtc_telephony.py` 1 处 `session.state` 写入字段（不变）
- 4 处 IllegalTransition handler (dead code 短期保留，followup 清理)
- 其他 sub-repo (isales-common / isales-api / isales-scheduler / isales-worker / isales-web) 完全不动

**受影响 spec**:
- `openspec/specs/call-state-machine/spec.md` (189 行 / 8 Requirements) — 修改 1 个 Req + 新增 1 个 Req + 改 1 处 event 名

**不受影响 spec**:
- `data-model/spec.md` (call_record.status 字段不变)
- `device-hardware/spec.md` (硬件 URC 触发 transition 写法不变)
- `interruption-detection/spec.md` (barge-in 检测逻辑不动)
- `transcript/spec.md` (state_warning 仍然是 transcript event 之一，schema 兼容)

**APIs / 协议**:
- 无（state machine 完全是 engine 内部组件）

**风险 + 缓解**:
- 业务流程"非法 transition"不再阻塞 → 真有代码 typo / 误用时 bug 在更深处爆而非 transition 点。**缓解**: warning log 写 transcript + journalctl 容易 grep，ops 仍可追溯。
- LEGAL_TRANSITIONS 表"诚意"打折，开发者可能不再认真遵守。**缓解**: spec 明确 advisory 性质 + warning log 暴露异常 + code review 检查。

**followup changes**（不在本 change scope）:
- 清理 4 处 `except IllegalTransition` handler dead code
- 进一步重构（如多 flag / event-driven 方向）属于另一次 architecture-level 决策，本次只做"软化 guard"这步最小风险动作
