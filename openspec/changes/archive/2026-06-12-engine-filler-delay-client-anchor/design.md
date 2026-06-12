## Context

垫词时间门控由 `tts-cache-and-gated-filler`（2026-06-08）引入：`_play_streaming` 进入后起一个 `filler_delay_ms` 计时器，到时若主回复首音频未出则播一句缓存垫词。当时 `_play_streaming` 在 PROCESSING 入口附近被调用，"`_maybe_filler` 任务创建时刻"≈"PROCESSING 进入时刻"，与 `filler/spec.md`、`data-model/spec.md` 的"进入 PROCESSING 后"措辞一致。

此后 `pipeline-stream-and-referee` → `engine-multi-referee-and-restructure` 把架构改成 **gate-first**：每轮先 `_run_gated_turn`（`run_loop.py:698`）spawn referees、await 预答门控，选出获胜路由，**再**调 `_play_streaming`（`run_loop.py:1531`）播获胜回复。于是 `_play_streaming` 进入时刻被推到了门控**之后**，而垫词计时器仍以"任务创建时刻"为锚——`processing_start`（`run_loop.py:648`，speech_end 处）与 `_play_streaming` 进入之间隔了整段门控等待，这段静默被排除在 `filler_delay_ms` 预算之外。代码锚点随重构静默漂移，规范措辞未变，二者背离。客户体感即"还没达到设定延迟，垫词就播了"。

现有实现（`run_loop.py:934-940`）：

```python
filler_task: asyncio.Task[None] | None = None
if filler is not None:
    async def _maybe_filler() -> None:
        await asyncio.sleep(filler_delay_s)         # 锚 = 任务创建时刻（门控之后）
        if first_audio_ms is None:
            await filler.start()
    filler_task = asyncio.create_task(_maybe_filler(), name="filler_gate")
```

`processing_start` 已作为参数传入 `_play_streaming`（`run_loop.py:877`），目前仅用于 `first_audio_ms` 指标（`run_loop.py:966-967`）。

## Goals / Non-Goals

**Goals:**

- 让 `filler_delay_ms` 的语义回归规范：自 **PROCESSING 进入（≈ 客户说完话）** 起算的客户可感知静默上限，门控等待计入预算。
- 修复 spec-code 漂移，并把锚点在 `filler` 规范里钉死，使其不再随调用点位置变化而漂移。
- 改动最小、可回退、不触碰 schema / 其他服务。

**Non-Goals:**

- 不补偿 `asr_eos_silence_ms`（ASR 端点静音，默认 ~0.4s）造成的"客户真正闭嘴"与"engine 判定 speech_end"之间的固有差——那需要预测客户停说话，属过度设计；本次接受这段残余偏移。
- 不改 `filler_delay_ms` 字段、默认值（600ms）、web 配置入口、缓存策略、垫词池选词逻辑。
- 不改 `last_user_speech_end_at` 的语义或新增字段。

## Decisions

### 决策 1：锚点用 `processing_start`，而非另传 `last_user_speech_end_at`

`_play_streaming` 已持有 `processing_start` 参数。把 `_maybe_filler` 从裸 `sleep(filler_delay_s)` 改为按 `processing_start` 计算剩余等待：

```python
async def _maybe_filler() -> None:
    remaining = filler_delay_s - (time.monotonic() - processing_start)
    if remaining > 0:
        await asyncio.sleep(remaining)
    if first_audio_ms is None:
        await filler.start()
```

`remaining <= 0`（门控已吃满预算）→ 不 sleep，直接判 `first_audio_ms` 并即刻播。

**备选：** 把 `session.last_user_speech_end_at`（`run_loop.py:790`，listen 循环内置位）传进来当锚。否决——它与 `processing_start` 仅差"`_await_user` 返回 + 几次状态转换"的微秒级间隔，却要额外穿参；且 `filler/spec.md` / `data-model/spec.md` 的既有措辞是"进入 PROCESSING 后"，`processing_start` 与规范字面一致。零收益不引入。

### 决策 2：门控等待计入预算（不是门控后另起二段延迟）

这是修复的核心语义点，也是客户体感的来源。`filler_delay_ms` = "自客户说完话起 AI 仍无声"的总预算，门控/ASR finalize 的静默属于这段预算内。实现上由决策 1 的 `remaining` 自然得到：门控耗时长 → `remaining` 小甚至 ≤0 → 垫词更早/即刻触发，正好遮住门控空档（旧实现完全遮不住门控段静默）。

### 决策 3：规范层钉死锚点 + 新增"超预算即刻播"场景

`filler` 能力的"时间门控播放"需求改为显式声明锚点 = PROCESSING 进入时刻、门控等待计入预算，并新增一条"门控耗时 ≥ 预算 → 进入播音即刻插垫词"场景。`data-model/spec.md:307-319` 的措辞（"进入 PROCESSING 后多久首音频仍未出"）已与新行为一致，无需 delta。

## Risks / Trade-offs

- **[门控偶发很慢时垫词触发提前甚至进入即播]** → 这正是期望行为：客户已等满预算，应当立即有声。`filler_enabled` 默认 false，仅显式开启的 campaign 受影响；缓存垫词零合成，不引入二次延迟。
- **[`processing_start` 仍比客户真正闭嘴晚 ~asr_eos_silence_ms]** → 已列入 Non-Goals，接受残余偏移；相比旧锚点（额外晚一整段门控）已大幅贴近客户侧。Mitigation：如未来要更准，单独 change 评估以 ASR 首个静音帧时间戳为锚。
- **[快轮次取消逻辑不变但需回归]** → 首音频先于剩余预算就绪 → `filler_task.cancel()`（`run_loop.py:955-958`）路径不变；单测覆盖"门控快 + LLM 快"仍不播。

## Migration Plan

1. 改 `isales-engine/isales_engine/run_loop.py` `_maybe_filler`（单函数、单文件）。
2. 加/调垫词门控单测三路径（门控 < 预算等剩余 / 门控 ≥ 预算即刻 / 快轮次取消）。
3. `cd ../isales-engine && .venv/bin/python -m pytest -q -k filler` 全绿。
4. scp engine `run_loop.py` 覆盖 ECS + `systemctl restart isales-engine`（沿用 `feedback_ecs_deploy_scp`）。
5. 回退：scp 旧 `run_loop.py` 覆盖 + restart 即可，无 schema / 状态迁移。

## Open Questions

- 真机验收用哪个 campaign（需 `filler_enabled=true` + 非空 `filler_phrases`）？apply 阶段确认；若 prod 无开启垫词的 campaign，则只做单测 + 服务级验证，真机验收随后续开启垫词的 campaign 顺带验。
