## MODIFIED Requirements

### Requirement: 状态集合

通话生命周期 SHALL 由以下状态构成：

- `INIT` —— 拨号尝试中
- `GREETING` —— 开场白播放
- `LISTENING` —— 等待用户说话
- `SPEAKING` —— TTS 播放 AI 回复
- `INTERRUPTED` —— 用户说话被判定为打断（短暂中转状态）
- `FILLER` —— 垫词播放
- `PROCESSING` —— AI 三层管线运行中
- `WRAPPING_UP` —— 目标达成后的收尾对话
- `ACTIVATING` —— 沉默激活话术播放
- `TRANSFERRING` —— 转人工流程（v1：播衔接话术 + 标记派发 + 主动挂断）
- `END` —— 通话结束

状态机 SHALL 维护合法转移集合 `LEGAL_TRANSITIONS: dict[CallState, set[CallState]]`，**作为业务流程的参考文档（advisory）**，用于在 transcript / 日志中区分"常规 transition"vs"非常规 transition"。任何不属于当前状态合法转移集合的 transition **SHALL NOT 阻塞业务执行**——`transition_to()` 在非常规 transition 时 SHALL 写 `state_warning` 事件 + `logger.warning` 日志、然后**继续完成 state 变更**。详细行为见 § "非法 transition 改 advisory 警告"。

历史背景：本 Requirement 之前规定非法 transition MUST 抛 `IllegalTransition` 阻塞业务（strict enforcer 语义）。该设计在通话场景的并发事件流下反复出问题（2026-05-27 起累计踩到 4 次需要补丁），故本 change 软化为 advisory tracker。`LEGAL_TRANSITIONS` 表的**内容**（哪些 transition 是常规的）不变，**只改 transition 不在表里时的响应方式**。

#### Scenario: 状态机起始

- **WHEN** scheduler 派发新通话任务
- **THEN** engine SHALL 创建新 session，初始 state = `INIT`

#### Scenario: 常规 transition 静默执行

- **WHEN** caller 调用 `transition_to(new_state)`，且 `new_state ∈ LEGAL_TRANSITIONS[current_state]`
- **THEN** 状态机 SHALL 静默完成 transition（写 `state_changed` 事件 + 设 `session.state = new_state`），不输出 warning。

#### Scenario: 非常规 transition 写 warning 但继续

- **WHEN** caller 调用 `transition_to(new_state)`，且 `new_state ∉ LEGAL_TRANSITIONS[current_state]`
- **THEN** 状态机 SHALL：
  1. 写 `logger.warning("state_transition_unusual current=<X> new=<Y> reason=<R>")`
  2. 追加 transcript 事件 `{type: "state_warning", attempted: <reason>, from_state: <current>, to_state: <new>}`
  3. **继续完成 transition**（设 `session.state = new_state`，写 state_history）
- 状态机 SHALL NOT 抛 `IllegalTransition` 异常。

## ADDED Requirements

### Requirement: 非法 transition 改 advisory 警告

`transition_to()` 在 transition 不在 `LEGAL_TRANSITIONS[current]` 集合时 SHALL NOT 抛异常阻塞业务。状态机 SHALL 把"非常规 transition"作为 advisory 信号（warning log + transcript event），由 ops 或后续 review 处理；状态机本身 MUST 继续完成 transition 让业务流程不被打断。

**Rationale**: 通话场景的事件本质并发（user 说话 / AI 说话 / VAD / silence timer / 网络抖动同时到达），FSM 静态 LEGAL_TRANSITIONS 表难以穷举所有合法路径。2026-05-27 ~ 2026-06-02 累计 4 次因为静态表漏列导致 engine crash（详见 design.md § Context）。advisory 模式让状态机继续作为业务流程文档 + 可读性 + transcript 记录工具，但不阻塞业务执行。

#### Scenario: 非常规 transition 不抛异常

- **WHEN** caller 调用 `sm.transition_to(NEW_STATE, reason="...")`，且 `NEW_STATE ∉ LEGAL_TRANSITIONS[session.state]`
- **THEN** `transition_to` MUST 完成 `session.state = NEW_STATE` 赋值且 MUST NOT 抛 `IllegalTransition` 异常
- **AND** transcript 中 SHALL 追加 `{type: "state_warning", attempted: <reason>, from_state: <prev_state.value>, to_state: <NEW_STATE.value>}` 事件

#### Scenario: warning 日志可 grep

- **WHEN** 非常规 transition 发生
- **THEN** journalctl SHALL 含一行 `state_transition_unusual current=<from> new=<to> reason=<r>` 格式日志，便于 ops `grep state_transition_unusual` 监控架构 drift

#### Scenario: force=True 参数 backward-compat

- **WHEN** caller 显式传 `force=True`
- **THEN** 行为等价于不传或传 `force=False`——transition 都会执行，区别只在 force=True 不再有 "跳过 guard" 的额外效果（因为默认就不阻塞）
- **AND** 既有 22 处 `transition_to(...)` 调用方代码无需修改

### Requirement: state_error 事件名迁移到 state_warning

历史 transcript 中可能存在 `state_error` 事件（本 change 实施之前的真 IllegalTransition 抛出时写入）。本 change 实施之后 engine MUST 写 `state_warning` 事件名而非 `state_error`，以反映"advisory 警告"而非"业务错误"的语义降级。

#### Scenario: 新通话不再产生 state_error 事件

- **WHEN** 本 change 实施后，engine 处理任何通话
- **THEN** transcript 中 MUST NOT 出现 `type: "state_error"` 事件；非常规 transition 一律写 `type: "state_warning"`

#### Scenario: 历史数据兼容

- **WHEN** 查询历史 call_record transcript（本 change 实施之前的通话）
- **THEN** 历史 `state_error` 事件保留原貌（数据库不动），消费方 SHOULD 同时识别 `state_error`（历史）+ `state_warning`（新）两种 event 名

### Requirement: IllegalTransition 类保留但不再抛出

`IllegalTransition` 异常类 SHALL 保留在 `state_machine.py` 中（避免 import 错误），但 `transition_to()` MUST NOT 再抛出该异常。现有 4 处 `except IllegalTransition` handler 短期保留作 dead code，由 followup change 清理。

#### Scenario: IllegalTransition 类可被 import 但不会被抛出

- **WHEN** 任何代码 `from isales_engine.state_machine import IllegalTransition`
- **THEN** import SHALL 成功（类定义存在）
- **AND** 运行时 `transition_to()` SHALL NOT 抛该异常类的实例

#### Scenario: 既有 except 块不引发回归

- **WHEN** 既有 `except IllegalTransition` 块包裹 `transition_to` 调用
- **THEN** 这些块 SHALL 永远不被执行（dead code），但不影响业务逻辑——transition 通过 advisory 路径完成 + caller 拿到正常 return
