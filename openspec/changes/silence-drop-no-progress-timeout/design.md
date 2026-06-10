# Design notes

## 关键决策：删机制、留枚举

`max_no_progress_seconds` 的**配置字段 + 专用计时器**整体删除；`HangupCause.NO_PROGRESS_TIMEOUT` 枚举成员**保留**。

理由：枚举成员有三处与「沉默无进展计时器」无关的用途——

1. `isales_engine/run_loop.py` `run_session` 顶层 `except`：未预期异常且 `hangup_cause` 未设时的兜底 cause；
2. `isales_engine/dial_consumer.py` `session_runner` 同款异常兜底；
3. `isales_worker/lead_state.py` `NORMAL_HANGUP_CAUSES` 分类（决定是否看 goal_achieved）。

删枚举会迫使我们为内部错误另立 cause（牵动 worker 重试/达成分类）并可能让历史 `call_record.hangup_cause="no_progress_timeout"` 行在 `HangupCause(...)` 处抛错。这两项都超出「删掉那个误导性的沉默超时字段」的用户意图，故保留枚举、仅删配置驱动的产出路径。

`no_progress_timeout` 因此从「配置驱动的业务挂断理由」降级为「引擎/dial 内部异常兜底理由」。`call-state-machine` 的 END-reason 单一来源清单仍登记它（仍可能出现），但删掉「`campaign.max_no_progress_seconds` 超时」这个不再成立的触发示例。

## 沉默超时挂断的唯一路径（删除后）

LISTENING 计时 ≥ `silence_threshold_ms`：

- 激活次数 < `max_silence_activations` → 播 `silence_phrases[i]` 激活，计数 +1，重新计时；
- 激活次数 ≥ `max_silence_activations` → 播 `silence_hangup_phrase`（空则直接挂）→ END(`silence_max_reached`)。

这就是用户口述的「达到最大激活次数后，客户再次达到沉默阈值 → 直接触发挂断」。引擎现有逻辑已是如此，本 change 不改这条路径，只删与它并行的冗余计时器（`_main_turn_loop` 里 `outcome.kind` 非 `user_final` 时的 `is_no_progress_exceeded` 分支退化为直接 `continue`）。

## engine 触点

- 删 `isales_engine/realtime/no_progress_timer.py` 整模块。
- `run_loop.py`：删 import、删 `no_progress_started`/`last_progress_ms` 起算与 595 行复位、删 567-580 计时器分支（保留 `continue`）。`_await_user_or_silence` 仍可返回非 `user_final` 的 outcome（`remote_hangup` 仍处理；其余 `continue`）。
- `runtime_config.py`：删 `RuntimeConfig.max_no_progress_seconds` 字段 + 装配赋值。
- `settings.py`：删 `engine_max_no_progress_seconds`（`ISALES_ENGINE_MAX_NO_PROGRESS_SECONDS`）。
- run_loop:209 的异常兜底 `hangup_cause = HangupCause.NO_PROGRESS_TIMEOUT.value` **保留**（见上）。

## alembic

新 migration `drop_campaign_max_no_progress_seconds`，down_revision = `b2f3a4c5d6e7`（当前 head）。

- upgrade: `op.drop_column("campaign", "max_no_progress_seconds")`
- downgrade: `op.add_column("campaign", sa.Column("max_no_progress_seconds", sa.Integer(), nullable=True))`

revision id 手编且不撞已有（见 `feedback_alembic_revision_id_collision` memory）；提交前 `alembic heads`/`history` 确认。
