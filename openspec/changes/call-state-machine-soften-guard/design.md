## Context

iSales 的 `state_machine.py` 是 `call-state-machine` capability 的实现核心 —— 一个传统 finite-state machine：定义 `LEGAL_TRANSITIONS: dict[CallState, set[CallState]]` 静态表，`transition_to()` 在 transition 不在表里时 `raise IllegalTransition`。Caller 用 `force=True` 跳过 guard 处理 unrecoverable shutdown 到 END。

**当前调用面**：22 处 `sm.transition_to(...)` 全部集中在 `run_loop.py` (lines 110-633) `_main_turn_loop`。`session.state` 字段被 5 处读取（run_loop 控制流 + rtc_telephony 写 call_record status）。28 处 `CallStatus` enum 引用横跨多个文件。

**反复踩的问题**：通话场景的并发事件本质（user 说话 / AI 说话 / VAD / silence timer / 网络抖动同时到达）跟"一时刻一状态、状态间清晰切换"的 FSM 模型不匹配。每次发现某种 transition 没列在 LEGAL 表里就：
- 加 LEGAL_TRANSITIONS 表条目（修补）
- 或加防护补丁（VAD corroboration / wall-clock duration / partial_monitor 提前启动）
- 或 caller 用 `force=True` 绕过

到 2026-06-02 还在踩：`INTERRUPTED → ACTIVATING (reason=silence_threshold)` IllegalTransition 让 `run_loop.py:419` crash，整通话变 `no_progress_timeout` hangup。

**业界对照**：Twilio Voice / Vonage Voice / WebRTC / Siri / Alexa / Dialogflow 这类语音/通话产品**都不用 strict FSM**，而是 event-driven + 多个并行 flag/task。但 iSales 已经积累了 22 处 transition + 188 行 state machine 测试 + 189 行 spec + 跨服务的 status field 数据契约，**完全重构是 5-6 天工程 + 高风险**。

**本 design 的范围**：在不破坏现有契约前提下，把 transition guard 从 enforcer 软化为 advisory。最小风险动 1 个文件 ~10 行代码。

## Goals / Non-Goals

**Goals:**
- 消除 `IllegalTransition` 抛异常导致 `run_session_unexpected_error` + `no_progress_timeout` 这类 crash 路径。
- 保留 `session.state` + `CallStatus` + transition 历史记录 + transcript event 流的可读性和数据契约。
- 让 22 处现有 `transition_to` 调用代码 + 4 处 `IllegalTransition` handler **零改动**。
- 提供一个明确的 transcript 信号 (`state_warning` event) 让 ops 可以 grep 出"出现非常规 transition"的通话，监控架构 drift。

**Non-Goals:**
- **不**重构成完全 event-driven 架构（多 flag / asyncio.Event 替代 enum state）—— 那是另一个 architecture-level change，本 change 只做"软化 guard"这一步最小动作。
- **不**清理 22 处 transition_to 调用 / 4 处 IllegalTransition handler 的 dead code —— 留作 followup（避免本 change 跨多文件 review 负担）。
- **不**修改 call_record `status` 字段 schema / scheduler+worker+web 跨服务消费 —— 保持数据契约不变。
- **不**改动 LEGAL_TRANSITIONS 表的内容（哪些 transition "应该合法"的业务设计）—— 那是另一个对话流设计 change。本 change 只改"非法 transition 时如何响应"。

## Decisions

### 决策 1: `transition_to` 默认不抛异常，改为 warning + 继续执行

非法 transition（不在 `LEGAL_TRANSITIONS[current]` 集合里）的行为：

```python
# Before (strict enforcer):
if not force and new_state not in LEGAL_TRANSITIONS.get(current, set()):
    session.append_event("state_error", ...)
    raise IllegalTransition(current, new_state, reason=reason)
# transition only executed if check passed or force=True
session.state = new_state

# After (advisory tracker):
if new_state not in LEGAL_TRANSITIONS.get(current, set()):
    logger.warning(
        "state_transition_unusual current=%s new=%s reason=%s",
        current.value, new_state.value, reason,
    )
    session.append_event("state_warning", ...)
# transition ALWAYS executed
session.state = new_state
```

**Rationale**: 这是路径 Y（保留 state 字段，软化 guard）的核心 ~5 行修改。让代码完全等价于"`force=True` 在所有 caller 隐式开启"。但保留显式的诊断信号 (`logger.warning` + `state_warning` event) 让 unusual transition 在 transcript / journalctl 里可见可 grep。

**Alternatives considered**:
- (A) 修 LEGAL_TRANSITIONS 表把 INTERRUPTED 加上 ACTIVATING (路径 Z) —— 治标，每次踩到新 illegal 还得改，5/27-29 已经迭代过 3 次说明这模式不可持续。
- (B) 完全废除 state machine 改 event-driven (路径 X) —— 5-6 天工程 + 跨服务数据契约改动，风险/收益比不好，应该单独决策。
- (C) 默认 `transition_to(force=True)`，调用方显式传 `force=False` 才 enforce —— 等价于路径 Y 但更绕，调用方代码需要 22 处改写。

选 (Y) 因为：业界主流（Twilio / WebRTC / Siri）都不用 strict FSM，但保留 state 字段作流程文档/可读性是合理折中；最小代码改动 + 现有契约不破坏 + 可后续逐步演进 (followup 清理 dead code → followup 改 event-driven 如果证明需要)。

### 决策 2: `state_error` event 名改为 `state_warning`

transcript event 名变更：从 `state_error` → `state_warning`。

**Rationale**: 之前抛异常时记 `state_error` 是合理的（业务流程"错"了被阻塞）。现在不阻塞了，语义降级为 advisory warning。event 名跟语义保持一致，让消费者（transcript 查询 / 报表）能区分两种新旧含义。

**注意 backward-compat**: 历史 call_record transcript 里可能已经有 `state_error` 事件，那是过往真 IllegalTransition 被 raise 时写的。本 change 之后**新通话不再产生 `state_error`**，但历史数据保留。如果消费方有强依赖 event 名，需更新 query — 但 grep 发现没有跨服务消费 transcript event 名做业务逻辑（只用于查看），属于安全改动。

**Alternative considered**: 完全不改 event 名，继续叫 `state_error`。但这会导致语义混淆 + transcript 上看不出 advisory vs strict 时代的差异。

### 决策 3: 保留 `IllegalTransition` 异常类 + 4 处 handler 不动

`IllegalTransition` 类定义保留，但 `transition_to` 不再抛它。4 处 `except IllegalTransition` handler 变成 dead code。

**Rationale**: 本 change 范围是"软化 guard"这一最小动作，跨文件改 handler 增加 review 负担和回归风险。dead code 由 followup change 清理（grep + 删 except 块）。

**Trade-off**: dead code 短期存在，可读性轻微下降。**缓解**: design.md + spec 明确标注 followup，linter 可能发出 unused-class 警告作提醒。

### 决策 4: `force=True` 参数保留但实际无意义

`transition_to(force=True)` 参数定义不删除，但内部逻辑变成：无论 force=True/False，都先 warn-if-unusual + 然后无条件 transition。

**Rationale**: 22 处现有调用方有几处显式传 `force=True`（END 终态触发等），如果删 force 参数会导致 22 处 review。保留参数 = 零调用方改动。

**Alternative considered**: 删 force 参数 + 改 22 处调用方。但本 change 范围明确说"调用方不动"，应该按这个原则执行。

## Risks / Trade-offs

- **Risk**: 真有代码 typo（`sm.transition_to(LISTENING)` 写成 `sm.transition_to(LISTENNING)` 之类）现在不会被 guard 抓住，bug 会在更深处爆。
  → **Mitigation**: `CallStatus` 是 enum，typo 会在 Python 解析时 `AttributeError`（不会 silent 通过）。`logger.warning` + `state_warning` event 让 unusual transition 可见。journalctl grep `state_transition_unusual` 监控架构 drift。

- **Risk**: LEGAL_TRANSITIONS 表"诚意"打折，开发者可能不再认真维护。
  → **Mitigation**: spec 里明确表是 advisory 性质 + 流程文档 + warning log 区分依据。code review 检查新 `transition_to` 调用是否合理（review 流程，非强制工具）。

- **Risk**: ops 监控可能依赖"transcript 含 state_error event = call abort"的查询。
  → **Mitigation**: 改 event 名前需检查 isales-web (web-admin-ui 查询 call_record transcript) 是否有此类查询；grep 已确认没有跨服务依赖 event 名。

- **Trade-off**: 失去"代码层乱跳"的编译期保护。
  → **接受**：通话场景的 bug 90% 来自 race / async timing / 事件并发，state machine 强制 transition 抓不到这些；而"代码层乱跳"在 Python typed enum + 22 处显式 transition_to 调用下极少发生（5/27-今天没观察到 typo 类 bug）。

- **Trade-off**: 5/27-29 加的 barge-in 防护补丁（`550902d` / `fa413b1` / `0c75805`）依赖 state machine 提供的 "INTERRUPTED state" 信号，本 change 不动这些补丁逻辑。
  → **保留**：本 change 只改 transition_to 的非法处理路径，state 字段本身 + 写入 INTERRUPTED 的逻辑不动，5/27-29 补丁继续工作。

## Migration Plan

**实施**: 本 change 不需要数据迁移、不需要 alembic、不需要 sub-repo 版本对齐（只动 isales-engine 内部）。

**部署顺序**:
1. mac local 改 `state_machine.py` + `test_state_machine.py`
2. 跑 isales-engine pytest 全绿
3. commit + push feature branch
4. scp 到 ECS `/opt/isales/current/isales-engine/isales_engine/state_machine.py`
5. `systemctl restart isales-engine`
6. mac dev-no-modem smoke 验证之前会 crash 的 `INTERRUPTED → ACTIVATING` 现在走 ACTIVATING 路径完成 silence_activation
7. （Windows 联合验收阶段）真拨号 e2e 验 barge-in 链路

**Rollback**: revert commit + scp 旧版本 `state_machine.py` 覆盖 ECS + restart。无数据迁移，无 schema 变更，rollback 5 分钟内完成。

**部署窗口**: 任何时段。engine restart 期间在途 call 会断（已有行为，与本 change 无关）。

## Open Questions

- **Q1**: `state_warning` event 是否需要在 `web-admin-ui` 的 transcript 查看界面显示成跟 `state_error` 不同的视觉样式（黄色 vs 红色）？
  → **暂定**: 不在本 change scope，followup web 改造时再考虑。本 change 只确保 backend 写出 `state_warning`，前端按现有 transcript event 渲染规则展示即可。

- **Q2**: 是否需要为 `state_warning` 加 metric / alert（如 unusual transition 1 分钟超过 N 次告警）？
  → **暂定**: 不在本 change scope，由观测体系 followup 决定（也是 followup change `engine-observability` 之类的范畴）。
