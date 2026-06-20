## MODIFIED Requirements

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
