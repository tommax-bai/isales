## Context

收尾（WRAPPING_UP）期的终止判定当前只有计数器（`evaluate_wrap_up` 看 `max_rounds`/`max_seconds`）。静音机制 `_await_user_or_silence`（run_loop.py:740-818）+ `evaluate_silence`（silence_detector.py:42-59）是 **phase-blind** 的：它在每个监听窗口运行（包括收尾期），但不读 `session.in_wrap_up`，于是收尾期照样跑「先激活、再挂断」阶梯。

call 215 的失败链（已在代码中核实）：normal turn 的 `closing` 路由（run_loop.py:1514-1534）播完告别语、置 `session.in_wrap_up=True`、返回 `CONTINUE` → 控制流回到外层循环的 `_await_user_or_silence` → 客户沉默 → 播「你好，还在么？」→ 最终客户挂机（`remote_hangup`）。`_gated_wrap_up_turn` 全程未被调用（它只在"进入收尾后客户又开口"时触发），所以收尾裁判方案对本通无效；**静音挂断是唯一承重墙**。

关键事实（多智能体 grounding 核实）：
- `_await_user_or_silence` 已在作用域内持有 `session`（run_loop.py:741）→ 让静音路径知道阶段**零额外管线**。
- `_await_user_or_silence` 只接收 `silence_cfg`（=`config.silence`，run_loop.py:541），**拿不到 `WrapUpConfig`** → 新阈值必须挂在 `SilenceConfig` 上。
- 静音"时钟"是**每监听窗口**重新计时（run_loop.py:753 每次循环重置 `listen_started`），非累计。窗口超时硬编码 `silence_threshold_ms/1000`（run_loop.py:754）。
- `wrap_up_completed.reason` 是封闭 `Literal["max_rounds","max_seconds"]`，历史上越界写入导致 `/calls` 500 三次；CI 有 `ISALES_ENGINE_STRICT_TRANSCRIPT=1` 兜底。`HangupEvent.reason` 是 free-form `str`。

## Goals / Non-Goals

**Goals:**
- 收尾期客户静默 `wrap_up_silence_hangup_ms` 后直接主动挂断，**不**播放重新激活话术。修复 call 215。
- 计数器（轮数/时长）保留为兜底。
- 复用现有静音机制（按阶段分支），不新建第二条静音线。
- 全局生效（所有 campaign），无 per-campaign 开关——收尾期重新激活本身是缺陷。
- 零 transcript schema 漂移：用 `HangupEvent(reason="wrap_up_silence")`，复用 `HangupCause.SILENCE_MAX_REACHED`。

**Non-Goals:**
- 收尾期专用旁路裁判（无心问题/同意挂断 → `tool:hangup`）—— 推迟到 Slice 2 `engine-wrap-up-bypass-referee`，需改 `_gated_wrap_up_turn` 并放宽 ai-pipeline「简化管线（WRAPPING_UP）」。
- per-campaign 静音挂断开关 / 收尾期保留一次重新激活——本 change 不做。
- 改 `evaluate_wrap_up` 计数器逻辑。

## Decisions

### D1：新阈值挂在 `SilenceConfig`，不挂 `WrapUpConfig`
`_await_user_or_silence` 只收 `silence_cfg`；`WrapUpConfig` 在静音消费点不可达。故 `wrap_up_hangup_ms` 加在 `SilenceConfig`（silence_detector.py），由 `runtime_config.py:294-301` 从 `campaign.wrap_up_silence_hangup_ms` 装配。
**备选**（否决）：放 `WrapUpConfig` 再额外把它透传进 `_await_user_or_silence`——多一层管线、且与「静音逻辑归 SilenceConfig」的内聚相悖。

### D2：`evaluate_silence` 加 `in_wrap_up: bool` 参数，收尾期直接判 hangup
`in_wrap_up=True` 时：`silence_elapsed_ms >= wrap_up_hangup_ms` → 立即 `decision="hangup"`，**完全跳过** activate 分支（收尾期 `max_activations` 实质为 0）。保持函数纯。
**备选**（否决）：在 `_gated_wrap_up_turn` 内另起静音计时——会重蹈 common 0.8.6 删掉的 silence-drop 重复，且收尾期客户静默时 `_gated_wrap_up_turn` 根本没在跑。

### D3（强制）：收尾期 `asyncio.wait` 超时改用 `wrap_up_hangup_ms`
因选了更长阈值（默认 6s > 中段 3s），若 wait 超时仍是 3s：窗口在 3s 醒来 → `elapsed < wrap_up_hangup_ms` → `evaluate_silence` 返回 wait → activate 阶梯被跳过故不累计 → 下窗口重置 → **挂断永不触发**。故 `_await_user_or_silence` 在 `session.in_wrap_up` 时，`asyncio.wait` 的 timeout MUST = `wrap_up_hangup_ms/1000`。这是本 change 最易漏的实现点。

### D4：复用 `HangupEvent` free-form reason + 复用 `HangupCause.SILENCE_MAX_REACHED`
`silence_hangup` handler（run_loop.py:553-567）按 `session.in_wrap_up` 分支：收尾期发 `HangupEvent(reason="wrap_up_silence", initiated_by="ai")`，否则原 `silence_max_reached`。`hangup_cause` 复用 `SILENCE_MAX_REACHED`（避免新增枚举 + 规避 `hangup_cause` 列可能的 Literal 校验风险）；分析维度靠 transcript 的 free-form reason 区分。
**备选**（否决）：新增 `HangupCause.WRAP_UP_SILENCE`——需确认 `CallRecordRead.hangup_cause` 非 Literal 校验，否则读回 500；收益（分析区分）不值这个风险，free-form reason 已够区分。

### D5：默认值 ~6000ms
比中段 `silence_threshold_ms`（默认 3000）长，给客户告别后思考时间；计数器仍是真正上限。具体默认值在实装时定（倾向 6000）。

## Risks / Trade-offs

- [全局行为变更，无开关] 部署即对所有 campaign 生效，收尾期不再重新激活 → **缓解**：这正是要修的 bug；每个触发点加「场景 + 移除条件」注释（多层兜底原则）；proposal/spec 明示为 deliberate global change。
- [慢思考客户被挂断] 收尾期跳过 activate 阶梯=无第二次机会 → **缓解**：默认阈值取得宽松（6s）；「客户再次开口重置窗口」保证只要客户出声就不挂。
- [D3 计时 bug 漏改] 只改 `evaluate_silence` 不改 wait 超时 → 挂断永不触发，change 形同 no-op → **缓解**：D3 列为强制 task + 计时回归测（阈值 6s > 3s 必须真触发）。
- [transcript schema 漂移] 误写 `wrap_up_completed.reason` → `/calls` 500 → **缓解**：用 `HangupEvent` free-form reason；跑 `ISALES_ENGINE_STRICT_TRANSCRIPT=1` 验 golden 测不枚举封闭 reason 集。
- [common 跨仓 pin] engine/api venv 未重装 isales-common → `make test-all` 看不到新列 → **缓解**：实装 task 显式列出重装步骤。

## Migration Plan

1. isales-common：加列 + schema + alembic（`down_revision='a2c4e6b8d0f2'`，commit 前重跑 `alembic heads`）+ 版本 0.8.21 + CHANGELOG。
2. engine/api venv 重装 isales-common；engine 改 `SilenceConfig`/`evaluate_silence`/`run_loop`/`runtime_config`。
3. web 加 `WrapUpTab.vue` 控件 + TS 类型。
4. 部署：common → 跑 alembic upgrade（生产 DB 加列，列有默认值故对在途通话安全）→ engine（scp + restart）→ web。
5. **回滚**：行为回滚=engine 回退即可（列保留无害，默认值不触发新路径仅当 engine 旧版忽略它）；DB 列可留（nullable/带 default，旧 engine 不读）。

## Open Questions

- `wrap_up_silence_hangup_ms` 默认值最终取 6000 还是更长（6000-8000）——实装时定，不阻塞 spec。
- 列定义 NOT NULL + server_default 还是 nullable + engine 默认兜底——倾向 NOT NULL server_default='6000' 对齐 `silence_threshold_ms` 既有形态；实装时定。
