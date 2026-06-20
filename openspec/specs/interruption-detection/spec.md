## Purpose

定义 SPEAKING 状态下用户说话是否构成"打断"的判定逻辑。误判为打断会让 AI 反应过度（被「嗯嗯」中断），漏判则用户感觉被 AI 强行覆盖。本规范覆盖判定算法、不可撤销策略、连续打断保护、ASR Provider 接入边界。
## Requirements
### Requirement: 打断判定不可撤销

一旦判定为"打断"，engine SHALL 立即停止 TTS 并切换状态，**MUST NOT 回退**到 SPEAKING（即使后续 ASR 中间结果显示其实是嗯嗯）。代价是可能误打断（用户先嗯嗯再说"你接着说"会被截）；收益是实现简单、状态机清晰、延迟低。

#### Scenario: 已判定打断后再收到白名单匹配

- **WHEN** engine 已停止 TTS 进入 INTERRUPTED 后，ASR 推送的下一个中间结果命中白名单
- **THEN** 维持 INTERRUPTED 状态，不恢复 TTS

### Requirement: 连续打断保护

当连续「打断 → PROCESSING → 打断」循环超过 `campaign.max_continuous_interruptions`（默认 3）时，engine SHALL 触发保护策略以避免无限循环。被计数的"打断"SHALL 同时包含 **SPEAKING 期间的播音 barge-in** 与 **PROCESSING 思考窗口（首音频释放前）的打断 abort**——二者对 `consecutive_interruption_count` 等同计数，使"客户在 AI 尚未出声时连续抢话"也能触发保护。保护策略 MUST 由 `campaign.continuous_interruption_strategy` 配置决定。

#### Scenario: 触发 short_reply 策略（默认）

- **WHEN** 连续打断次数达到上限 **且** `campaign.continuous_interruption_strategy = "short_reply"`
- **THEN** 角色 LLM prompt 临时追加「请用一句话回应」，避免长 TTS 再被打断

#### Scenario: 触发 listen_only 策略

- **WHEN** 连续打断次数达到上限 **且** `campaign.continuous_interruption_strategy = "listen_only"`
- **THEN** AI 主动说一句「您请说」，进入纯听模式，等用户 speech_end 后再回应

#### Scenario: 思考窗口的打断同等计入保护计数

- **WHEN** PROCESSING 思考窗口被判定打断、`_run_gated_turn` 取消未出声本轮并 abort
- **THEN** engine SHALL `consecutive_interruption_count += 1`（与播音 barge-in 同步），使连续的思考窗口抢话累计到 `max_continuous_interruptions` 后触发同一保护策略

#### Scenario: 完整轮次后计数器重置

- **WHEN** 用户完成一轮完整对话（无打断的 SPEAKING）
- **THEN** 连续打断计数器清零

### Requirement: ASR Provider 抽象与 VAD 来源

打断判定 SHALL 基于流式 ASR 的中间结果与 VAD 事件；engine MUST NOT 依赖独立的 VAD 模型。所有接入的 ASR Provider MUST 实现 `isales-common.providers.asr` 接口。

#### Scenario: ASR Provider 必须支持的能力

- **WHEN** 接入新的 ASR Provider
- **THEN** 该 Provider 必须实现 `isales-common.providers.asr` 接口，提供：流式中间结果（partial result）持续推送、speech_start / speech_end VAD 事件（带时间戳）

#### Scenario: v1 默认 ASR Provider

- **WHEN** v1 部署 / 未配置自定义 ASR Provider
- **THEN** 使用火山引擎（豆包）实时语音识别作为默认实现

### Requirement: 与 FILLER / WRAPPING_UP 状态的交互

打断判定逻辑 MUST 在 FILLER 和 WRAPPING_UP 状态下保持一致；engine SHALL 仅调整后续 PROCESSING 路径。

#### Scenario: FILLER 期间用户说话被判定为打断

- **WHEN** FILLER 状态正在播放垫词，ASR 中间结果触发"打断"判定
- **THEN** engine 停止垫词、丢弃当前 PROCESSING 中的 AI 管线、把用户输入作为新一轮处理

#### Scenario: WRAPPING_UP 期间被打断

- **WHEN** WRAPPING_UP 状态触发"打断"判定
- **THEN** 判定逻辑不变；进入 PROCESSING 后走简化管线（仅 main LLM 流式，跳过 referee）

### Requirement: 可组合规则树打断判定

SPEAKING / FILLER 状态下，**以及 PROCESSING 思考窗口（本轮回复已进入处理、但首个 TTS 音频尚未释放的生成阶段）下**，engine SHALL 用一棵**可组合规则树**判定用户的 ASR partial 文本是否构成"打断"，规则树由 campaign 配置（见 § "打断规则树配置与装配"）。规则树对每个 partial 求值，返回 `triggered`（构成打断）或 `ignored`（非打断，TTS 继续 / 本轮生成继续、用户输入丢弃）。

判定核（规则树结构、阈值、白名单）在 SPEAKING/FILLER 与 PROCESSING 思考窗口下**完全一致**——同一棵 `evaluate_partial` 规则树、同样的 `interruption_min_chars` / `duration` / 白名单；engine MUST NOT 为思考窗口引入第二套判定逻辑或独立阈值。本要求仅扩大 `_partial_monitor` 的**生效范围**，不改判定算法。

规则节点分两类（参照 voxen `core/interruption/`）：

- **叶子规则**：
  - `keyword`：文本（trim 尾部标点后）命中词集任一项即真；`match` 字段 `"contains"`（子串，默认）或 `"exact"`（整段相等）。
  - `length`：`len(text.strip())` rune 数 ≥ `value` 即真。
  - `duration`：自用户 speech_start 起的 elapsed 毫秒数 ≥ `value_ms` 即真。
  - `regex`：`re.search(pattern, text)` 命中即真。
  - `split_by_delimiter`：文本含 `delimiters` 任一分隔符即真。
  - `none`：恒假（= 禁用打断）。
- **组合规则**：`and`（全子真，短路）、`or`（任一子真，短路）、`not`（取反单个子规则）。

判定结果不可撤销策略、连续打断保护、与 FILLER/WRAPPING_UP 交互等其它 Requirement 不变。规则树**只**替换原"白名单 + 时长"双条件的判定核，barge-in 触发入口仍是 `_partial_monitor` 走该规则树（唯一入口，VAD 不再独立触发，见 § VAD-source cancel deprecate）。`_partial_monitor` 的生效守卫 SHALL 从「正在播音（`current_speaking_task` 存在）」放宽为「本轮回复正在进行（思考窗口 **或** 播音）**或**正在播音」，使思考窗口的 partial 也经规则树求值；该放宽 MUST 严格叠加、MUST NOT 改变 LISTENING（无回合进行、无播音）期间不触发的现有行为——首句用户输入仍由正常 PROCESSING 入口处理，不被规则树误判为打断。思考窗口判定为 `triggered` 时的后续门控行为（取消未出声候选、合并客户句、经 main 管线重答、不进 restructure）见 ai-pipeline § "思考窗口被打断（首音频释放前）"。

#### Scenario: 命中"忽略语气词"子规则视为非打断

- **WHEN** SPEAKING 期间 ASR partial 文本（trim 尾部标点后）命中规则树中某 `keyword` 叶子的词集（如默认树里的「嗯」「好的」），且该叶子被 `not` 包裹用于忽略语气词
- **THEN** 规则树求值为 `ignored`，TTS 继续，用户输入丢弃；`evaluate_partial` 返回 `InterruptionVerdict(verdict="ignored", reason=<命中规则的 provenance>)`

#### Scenario: 字数低于 length 叶子阈值视为非打断

- **WHEN** SPEAKING 期间 ASR partial 文本 strip 后字符数 < 规则树中 `length` 叶子的 `value`（默认树取 `campaign.interruption_min_chars`，默认 2）
- **THEN** 规则树求值为 `ignored`（`and` 短路），TTS 继续；`evaluate_partial` 返回 `verdict="ignored"`
- **AND** `_partial_monitor` SHALL 记录 `logger.info("partial_monitor_skip ... reason=length")` 以便 ops 调参

#### Scenario: 时长低于 duration 叶子阈值视为非打断

- **WHEN** SPEAKING 期间自用户 speech_start 至当前的 elapsed 毫秒数 < 规则树中 `duration` 叶子的 `value_ms`（默认树取 `campaign.interruption_min_duration_ms`，默认 400）
- **THEN** 规则树求值为 `ignored`，TTS 继续

#### Scenario: regex / 分隔符叶子命中触发打断

- **WHEN** campaign 配置了含 `regex` 或 `split_by_delimiter` 叶子的规则树，且 ASR partial 文本命中该叶子（其余组合条件满足）
- **THEN** 规则树求值为 `triggered`，engine 立刻停止 TTS、状态 INTERRUPTED → PROCESSING，用 ASR 终态结果作为本轮用户输入

#### Scenario: 整棵树求值满足触发打断

- **WHEN** ASR partial 文本使规则树根节点求值为真（如默认树 `AND(NOT keyword, length≥interruption_min_chars, duration≥阈值)` 全过）
- **THEN** engine 立刻停止 TTS、状态转为 INTERRUPTED → PROCESSING，使用 ASR 终态结果作为本轮用户输入；`evaluate_partial` 返回 `verdict="triggered"`

#### Scenario: 可组合规则按 and/or/not 嵌套求值

- **WHEN** campaign 配置 `AND( OR(regex_A, keyword_B), NOT(keyword_语气词), duration )` 这样的嵌套树，partial 文本命中 `regex_A`、不在语气词集、时长够
- **THEN** 规则树求值为 `triggered`；若文本同时命中语气词集（`NOT` 子为假），则 `and` 短路求值为 `ignored`

#### Scenario: 思考窗口（首音频释放前）的实质性 partial 触发打断

- **WHEN** 本轮回复已进入处理（已收到第一句 A 的 ASR final、`in_processing_turn` 为真）但首个 TTS 音频尚未释放（`current_speaking_task` 为 None），客户的第二句 B 的 ASR partial 使规则树根节点求值为真（按与 SPEAKING 完全相同的阈值/白名单）
- **THEN** `_partial_monitor` SHALL 置 `session.interruption_signaled = True` 并记 `interruption` 事件（与 SPEAKING 同动作），由 `_run_gated_turn` 据此取消未出声的本轮（详见 ai-pipeline § "思考窗口被打断（首音频释放前）"）

#### Scenario: 思考窗口的语气词/超短句仍被忽略

- **WHEN** 思考窗口期间客户的 partial 命中白名单语气词或字符数 < `interruption_min_chars`
- **THEN** 规则树求值为 `ignored`，本轮生成**不**被打断、继续到首音频释放——忽略标准与 SPEAKING 期间逐字节一致

#### Scenario: LISTENING（无回合进行）期间不触发打断

- **WHEN** engine 处于 LISTENING、`_await_user_or_silence` 正等待首句用户输入（`in_processing_turn` 为假且无播音任务），收到首句 A 的 ASR partial
- **THEN** `_partial_monitor` 守卫 SHALL `continue`、MUST NOT 求值规则树、MUST NOT 置 `interruption_signaled`；首句 A 经正常 PROCESSING 入口处理，不被误判为打断

### Requirement: 打断规则树配置与装配

`campaign` 表 SHALL 持有 `interruption_rules` JSONB 列存放规则树。`isales_engine.realtime.interruption_detector` SHALL 提供 factory 把规则树 dict **编译一次**成 `Rule` 对象树（装配 `InterruptionConfig` 时编译，`evaluate_partial` 每个 partial 只调求值，不重建）。非法规则树（未知 `type` / 结构错）MUST 在装配期 fail-fast 并 ERROR 日志。

向后兼容 SHALL 由"缺省合成默认树"实现：`interruption_rules` 为 NULL 时，`runtime_config` MUST 从 legacy 标量列合成默认树 `AND( NOT keyword(match="exact", values=interruption_whitelist), length(value=interruption_min_chars), duration(value_ms=interruption_min_duration_ms) )`。其中 `length` 叶子的 `value` MUST 取 `campaign.interruption_min_chars`（NOT NULL，默认 2）而非历史硬编码 `2`；存量 campaign 经迁移回填 `interruption_min_chars=2` 后，默认树与历史「白名单(精确) + 时长 + 字数≥2」**逐字节等价**。engine MUST NOT 因 `interruption_rules` 为 NULL 报错。

#### Scenario: 缺省合成的默认树取 interruption_min_chars

- **WHEN** campaign 的 `interruption_rules` 为 NULL（非高级模式 / 存量 campaign 未配规则树）
- **THEN** `runtime_config` SHALL 从 `interruption_whitelist` + `interruption_min_chars` + `interruption_min_duration_ms` 合成默认树（keyword 用 `match="exact"`、length=`interruption_min_chars`、duration=`interruption_min_duration_ms`）
- **AND** 当 `interruption_min_chars` 取默认 2 时，默认树的 `triggered`/`ignored` 判定 MUST 与历史 `evaluate_partial`（whitelist 精确匹配 → 字数≥2 → 时长）逐字节一致

#### Scenario: campaign 配置自定义规则树覆盖默认

- **WHEN** campaign 的 `interruption_rules` 为非 NULL 合法规则树
- **THEN** engine SHALL 编译该树用于判定，忽略 legacy 标量列（含 `interruption_min_chars`）派生的默认树

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

### Requirement: 打断收声渐隐淡出

判定打断后停止 TTS 时，engine SHALL 对「尚未推送给客户」的出向音频施加一段可配置时长的下行增益淡出斜坡，使人声平滑收敛到零，MUST NOT 在帧边界处把振幅硬切到零。淡出时长由 `campaign.barge_in_fadeout_ms` 决定（默认 100ms）；该值为 `0` 时 engine SHALL 保留硬切行为（不淡出）。淡出 MUST 仅作用于出向 TTS 人声，背景底噪（ambient mix）在淡出期间 MUST 维持不变。

#### Scenario: 默认淡出收声

- **WHEN** SPEAKING 状态被判定打断，且 `campaign.barge_in_fadeout_ms > 0`
- **THEN** engine 对队首「将播」音频施加下行增益斜坡至零、丢弃其余待播帧，pump 在淡出窗口内播完渐弱人声后落入静音；人声平滑收敛，无爆音 click

#### Scenario: 淡出时长可配置且 0 表示硬切

- **WHEN** `campaign.barge_in_fadeout_ms == 0` 时发生打断
- **THEN** engine 立即清空全部待播 TTS（旧硬切行为），不施加斜坡

#### Scenario: 背景底噪不随人声淡出

- **WHEN** 打断收声淡出期间 campaign 启用了 ambient 背景混音
- **THEN** 仅 TTS 人声渐隐，背景底噪（room tone）持续不变，淡出后只剩背景底噪而非死寂

### Requirement: 出向 TTS 经常驻播放缓冲

engine SHALL 使出向 TTS 始终经一条常驻的播放缓冲 + 推流 pump，无论 campaign 是否启用 ambient 背景混音；engine MUST NOT 在「无 ambient」时走无缓冲的直推路径。此约束确保打断淡出在 ambient 开/关两种模式下行为一致（淡出需作用于尚未推出的缓冲音频，无缓冲路径无法淡出）。

#### Scenario: 无 ambient 时仍经播放缓冲

- **WHEN** campaign 未启用 ambient（`ambient_audio` 未配置）且 AI 正在 SPEAKING
- **THEN** 出向 TTS 经常驻 pump 推流（背景帧为静音、混音原样透传 TTS），被打断时与 ambient 启用时走同一条淡出路径

## Configuration

`campaign` 表新增字段：

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `interruption_whitelist` | JSONB array | `["嗯","嗯嗯","好","好的","哦","哦哦","对","是的"]` | 白名单短语，整段完全匹配 |
| `interruption_min_duration_ms` | int | 800 | 时长阈值，低于此值视为非打断 |
| `interruption_min_chars` | int | 2 | 字数阈值（≥1），缺省默认树 `length` 叶子取值；低于此 rune 数视为非打断，仅 `interruption_rules` 为 NULL 时生效 |
| `max_continuous_interruptions` | int | 3 | 触发保护策略前允许的连续打断次数 |
| `continuous_interruption_strategy` | enum | `short_reply` | `short_reply` / `listen_only` |

> 配置粒度：Campaign 级。不做全局默认覆盖、不做 Role 级独立配置。
