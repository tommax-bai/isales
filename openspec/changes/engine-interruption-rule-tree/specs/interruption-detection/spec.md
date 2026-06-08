## RENAMED Requirements

- FROM: `### Requirement: 双条件打断判定`
- TO: `### Requirement: 可组合规则树打断判定`

## MODIFIED Requirements

### Requirement: 可组合规则树打断判定

SPEAKING / FILLER 状态下 engine SHALL 用一棵**可组合规则树**判定用户的 ASR partial 文本是否构成"打断"，规则树由 campaign 配置（见 § "打断规则树配置与装配"）。规则树对每个 partial 求值，返回 `triggered`（构成打断）或 `ignored`（非打断，TTS 继续、用户输入丢弃）。

规则节点分两类（参照 voxen `core/interruption/`）：

- **叶子规则**：
  - `keyword`：文本（trim 尾部标点后）命中词集任一项即真；`match` 字段 `"contains"`（子串，默认）或 `"exact"`（整段相等）。
  - `length`：`len(text.strip())` rune 数 ≥ `value` 即真。
  - `duration`：自用户 speech_start 起的 elapsed 毫秒数 ≥ `value_ms` 即真。
  - `regex`：`re.search(pattern, text)` 命中即真。
  - `split_by_delimiter`：文本含 `delimiters` 任一分隔符即真。
  - `none`：恒假（= 禁用打断）。
- **组合规则**：`and`（全子真，短路）、`or`（任一子真，短路）、`not`（取反单个子规则）。

判定结果不可撤销策略、连续打断保护、与 FILLER/WRAPPING_UP 交互等其它 Requirement 不变。规则树**只**替换原"白名单 + 时长"双条件的判定核，barge-in 触发入口仍是 `_partial_monitor` 走该规则树（唯一入口，VAD 不再独立触发，见 § VAD-source cancel deprecate）。

#### Scenario: 命中"忽略语气词"子规则视为非打断

- **WHEN** SPEAKING 期间 ASR partial 文本（trim 尾部标点后）命中规则树中某 `keyword` 叶子的词集（如默认树里的「嗯」「好的」），且该叶子被 `not` 包裹用于忽略语气词
- **THEN** 规则树求值为 `ignored`，TTS 继续，用户输入丢弃；`evaluate_partial` 返回 `InterruptionVerdict(verdict="ignored", reason=<命中规则的 provenance>)`

#### Scenario: 字数低于 length 叶子阈值视为非打断

- **WHEN** SPEAKING 期间 ASR partial 文本 strip 后字符数 < 规则树中 `length` 叶子的 `value`（默认树为 2）
- **THEN** 规则树求值为 `ignored`（`and` 短路），TTS 继续；`evaluate_partial` 返回 `verdict="ignored"`
- **AND** `_partial_monitor` SHALL 记录 `logger.info("partial_monitor_skip ... reason=length")` 以便 ops 调参

#### Scenario: 时长低于 duration 叶子阈值视为非打断

- **WHEN** SPEAKING 期间自用户 speech_start 至当前的 elapsed 毫秒数 < 规则树中 `duration` 叶子的 `value_ms`（默认树取 `campaign.interruption_min_duration_ms`，默认 800）
- **THEN** 规则树求值为 `ignored`，TTS 继续

#### Scenario: regex / 分隔符叶子命中触发打断

- **WHEN** campaign 配置了含 `regex` 或 `split_by_delimiter` 叶子的规则树，且 ASR partial 文本命中该叶子（其余组合条件满足）
- **THEN** 规则树求值为 `triggered`，engine 立刻停止 TTS、状态 INTERRUPTED → PROCESSING，用 ASR 终态结果作为本轮用户输入

#### Scenario: 整棵树求值满足触发打断

- **WHEN** ASR partial 文本使规则树根节点求值为真（如默认树 `AND(NOT keyword, length≥2, duration≥阈值)` 全过）
- **THEN** engine 立刻停止 TTS、状态转为 INTERRUPTED → PROCESSING，使用 ASR 终态结果作为本轮用户输入；`evaluate_partial` 返回 `verdict="triggered"`

#### Scenario: 可组合规则按 and/or/not 嵌套求值

- **WHEN** campaign 配置 `AND( OR(regex_A, keyword_B), NOT(keyword_语气词), duration )` 这样的嵌套树，partial 文本命中 `regex_A`、不在语气词集、时长够
- **THEN** 规则树求值为 `triggered`；若文本同时命中语气词集（`NOT` 子为假），则 `and` 短路求值为 `ignored`

## ADDED Requirements

### Requirement: 打断规则树配置与装配

`campaign` 表 SHALL 持有 `interruption_rules` JSONB 列存放规则树。`isales_engine.realtime.interruption_detector` SHALL 提供 factory 把规则树 dict **编译一次**成 `Rule` 对象树（装配 `InterruptionConfig` 时编译，`evaluate_partial` 每个 partial 只调求值，不重建）。非法规则树（未知 `type` / 结构错）MUST 在装配期 fail-fast 并 ERROR 日志。

向后兼容 SHALL 由"缺省合成默认树"实现：`interruption_rules` 为 NULL 时，`runtime_config` MUST 从 legacy 列合成默认树 `AND( NOT keyword(match="exact", values=interruption_whitelist), length(value=2), duration(value_ms=interruption_min_duration_ms) )`，使**未配置规则树的 campaign 行为与历史「白名单(精确) + 时长 + 字数≥2」逐字节等价**。engine MUST NOT 因 `interruption_rules` 为 NULL 报错。

#### Scenario: 缺省合成的默认树等价历史行为

- **WHEN** campaign 的 `interruption_rules` 为 NULL（存量 campaign 未配规则树）
- **THEN** `runtime_config` SHALL 从 `interruption_whitelist` + `interruption_min_duration_ms` 合成默认树（keyword 用 `match="exact"`、length=2、duration=该列值）
- **AND** 对任意 ASR partial 输入，默认树的 `triggered`/`ignored` 判定 MUST 与历史 `evaluate_partial`（whitelist 精确匹配 → 字数≥2 → 时长）一致

#### Scenario: campaign 配置自定义规则树覆盖默认

- **WHEN** campaign 的 `interruption_rules` 为非 NULL 合法规则树
- **THEN** engine SHALL 编译该树用于判定，忽略 legacy 列派生的默认树

#### Scenario: 非法规则树装配期 fail-fast

- **WHEN** `interruption_rules` 含未知 `type` 或结构非法（如 `and` 缺 `rules`）
- **THEN** factory MUST 抛出明确错误并 ERROR 日志（坏配置应在 api 写入时已被校验拦下，运行时为兜底）

### Requirement: VAD-source cancel deprecate, VAD 仅作 corroboration mirror

`_vad_monitor` task（`run_loop.py`）SHALL 保留作 `session.vad_voice_active_ms` mirror —— `_partial_monitor` 的防自环 corroboration（550902d）仍需该状态判断 partial 是否真有人声协同。但 `_vad_monitor` MUST NOT 独立触发 `speaking_task.cancel()`，也 MUST NOT 写 transcript event `source="vad"`。barge-in 触发**唯一**入口 SHALL 是 `_partial_monitor` 走规则树判定。

**Rationale**：VAD energy 信号不抗噪（噪音也有 energy），2026-06-03 真 mic 实测多次因 ambient noise burst 误触发打断 AI 长回应；改用 ASR 文本经规则树判定（vendor model 不把噪音识别成文字）是抗噪正解。（本要求吸收自被 SUPERSEDED 的 change `interruption-detection-text-length-gate`。）

#### Scenario: vad_monitor 不再独立 cancel

- **WHEN** `_vad_monitor` 内 `voice_active_ms >= interruption_cfg.min_duration_ms` 满足
- **THEN** `_vad_monitor` MUST NOT 调用 `speaking_task.cancel()`，也 MUST NOT 写 `{type:"interruption", source:"vad"}` transcript event
- **AND** 仅 mirror `session.vad_voice_active_ms`（供 `_partial_monitor` corroboration）

#### Scenario: source="vad" interruption event 新通话不再产生

- **WHEN** 任何本 change 部署后的新 call_record 生成 transcript
- **THEN** transcript MUST NOT 含 `{type:"interruption", source:"vad", ...}` event
- **AND** 历史 call_record 的 `source="vad"` event 保留原貌（DB 不动）
