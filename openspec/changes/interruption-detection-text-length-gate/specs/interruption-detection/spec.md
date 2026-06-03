## MODIFIED Requirements

### Requirement: 双条件打断判定

SPEAKING 状态下 engine SHALL 根据**三个独立条件**判定用户说话是否构成"打断"。**任一条件不满足时 engine MUST 视为非打断**：白名单短语命中 OR 字数 < 最小阈值 OR 时长 < 持续时长阈值。

新增"字数 < 最小阈值"条件 (2026-06-03 change `interruption-detection-text-length-gate`) — vendor ASR partial 文字内容是抗噪 barge-in 信号: vendor model 只把人声识别成中文文字, ambient noise 通常识别不出文字 / 识别成空字符串。用字数 ≥ N (default 2) 作为闸, 噪音天然过不去。

历史背景: 原"双条件"(whitelist + min_duration_ms) 设计在 2026-06-03 真 mic 实测发现, 配合并行的 `_vad_monitor` 独立 VAD-source cancel (fa413b1 commit) 容易被 ambient noise 误触发打断 AI 长回应 (实测 mac mic baseline RMS ~800-1100, 椅子/呼吸 burst 1500-2000 持续 200ms 触发 vad cancel)。本 change 把 barge-in 触发完全收敛到 partial_monitor 走 evaluate_partial, 加 min_text_length 作为新的过滤条件。VAD-source cancel 在另一 Requirement 单独说明 (deprecate)。

#### Scenario: 用户说出白名单短语

- **WHEN** SPEAKING 期间 ASR 中间结果文本完全等于 `campaign.interruption_whitelist` 中任一短语（如「嗯」「好的」）
- **THEN** 不视为打断，TTS 继续，用户输入将被丢弃。`evaluate_partial` 返回 `InterruptionVerdict(verdict="ignored", reason="whitelist")`

#### Scenario: 用户说话字数低于最小阈值

- **WHEN** SPEAKING 期间 ASR 中间结果文本 strip 后字符数 < `campaign.interruption_min_text_length` (default 2)
- **THEN** 不视为打断，TTS 继续，用户输入将被丢弃。`evaluate_partial` 返回 `InterruptionVerdict(verdict="ignored", reason="text_too_short")`
- **AND** `_partial_monitor` SHALL 记录 `logger.info("partial_monitor_skip_text_too_short text=%r min=%d")` 以便 ops 调参

#### Scenario: 用户说话时长低于阈值

- **WHEN** SPEAKING 期间 ASR speech_start 至当前时刻的间隔小于 `campaign.interruption_min_duration_ms`（默认 800ms）
- **THEN** 不视为打断，TTS 继续。`evaluate_partial` 返回 `InterruptionVerdict(verdict="ignored", reason="below_threshold")`

#### Scenario: 用户说话满足打断条件 (三条件全过)

- **WHEN** ASR 中间结果文本不在白名单中 **且** 字符数 ≥ `min_text_length` **且** 持续时长已超过 `min_duration_ms`
- **THEN** engine 立刻停止 TTS、状态转为 INTERRUPTED → PROCESSING，使用 ASR 终态结果作为本轮用户输入。`evaluate_partial` 返回 `InterruptionVerdict(verdict="triggered", reason="exceeds")`

#### Scenario: per-campaign 配置不同阈值

- **WHEN** 业务场景要求快速打断 (e.g. 客服快回应, user 单字"行"立即触发)
- **THEN** 该 campaign 配 `interruption_min_text_length = 1` override default 2; `evaluate_partial` 行为按配置阈值过滤

## ADDED Requirements

### Requirement: VAD-source cancel deprecate, VAD 仅作 corroboration mirror

`_vad_monitor` task (run_loop.py) SHALL 保留作 `session.vad_voice_active_ms` mirror — partial_monitor (550902d commit 加的防自环 corroboration) 仍需要该状态判断 partial 是否真有人声协同。但 `_vad_monitor` MUST NOT 独立触发 `speaking_task.cancel()` 也 MUST NOT 写 transcript event `source="vad"`。

barge-in 触发**唯一**入口 SHALL 是 partial_monitor 走 evaluate_partial (含 whitelist + min_text_length + min_duration_ms 三条件)。

**Rationale**: VAD energy 信号本质不抗噪 (noise 也有 energy), 2026-06-03 实测多次因 ambient noise burst 误触发打断 AI 长回应。改用 ASR text content 信号 (vendor model 不把噪音识别成文字) 是抗噪正解。VAD 保留作 corroboration 防自环 (engine TTS echo 触发 partial 时也需 vad active 协同才接受) 但不再独立 cancel。

#### Scenario: vad_monitor task 不再独立触发 cancel

- **WHEN** `_vad_monitor` 内 `voice_active_ms >= interruption_cfg.min_duration_ms` 满足
- **THEN** `_vad_monitor` MUST NOT 调用 `speaking_task.cancel()` 也 MUST NOT 写 transcript event `{type:"interruption", source:"vad"}`
- **AND** 仅 mirror `session.vad_voice_active_ms = voice_active_ms` (用于 partial_monitor 的 corroboration check)

#### Scenario: source="vad" interruption event 新通话不再产生

- **WHEN** 任何新 call_record (本 change 部署后) 生成 transcript
- **THEN** transcript MUST NOT 含 `{type:"interruption", source:"vad", ...}` event
- **AND** 若 barge-in 真触发, 仅出现 partial_monitor 触发的 cancel (event 由现有 partial-source interruption 路径写, 不在本 change scope)

#### Scenario: 历史数据兼容

- **WHEN** 查询本 change 部署之前的 call_record transcript
- **THEN** 历史 `source="vad"` interruption events 保留原貌 (数据库不动)
- **AND** 消费方 (web admin / 分析报表) SHOULD 同时识别 `source="vad"` (历史) 和 `source` 缺失 / `source="partial"` (新 partial-only path)

### Requirement: InterruptionConfig 加 min_text_length 字段

`isales_engine.realtime.interruption_detector.InterruptionConfig` dataclass SHALL 新增字段 `min_text_length: int = 2` (default value)。`evaluate_partial(text, ..., config)` MUST 在 whitelist check 之后 / min_duration_ms check 之前 应用 text length gate:

```
if text.strip() in config.whitelist:        → ignored("whitelist")
if len(text.strip()) < config.min_text_length: → ignored("text_too_short")
if elapsed_ms < config.min_duration_ms:    → ignored("below_threshold")
return triggered("exceeds")
```

字段是 schema-additive (有 default 值), **既有 caller (无 min_text_length 参数构造 InterruptionConfig 的代码) MUST 不受影响**, dataclass default 自动填 2。

#### Scenario: dataclass default backward compat

- **WHEN** 既有代码用旧 signature `InterruptionConfig(whitelist=[...], min_duration_ms=800)` 构造 (不传 min_text_length)
- **THEN** dataclass MUST 自动填 `min_text_length=2` (default), 不报 TypeError, 不破坏既有 caller

#### Scenario: runtime_config 从 PG campaign 加载 min_text_length

- **WHEN** `runtime_config.py::build_runtime_config` 读取 PG campaign 行构造 InterruptionConfig
- **THEN** SHALL 读取 `campaign.interruption_min_text_length` (int, default 2) 字段填进 InterruptionConfig.min_text_length
- **AND** 若 campaign 行无该字段 (旧 DB 未 migrate), MUST fallback to InterruptionConfig dataclass default 2 不抛异常
