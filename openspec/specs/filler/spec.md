## Purpose

垫词在 AI 管线处理期间播放，用于覆盖 LLM/TTS 延迟。本规范定义触发场景、启动时机、选择策略、音频来源、失败兜底与数据模型。垫词配置 MUST 绑定在 Campaign 级（与音色一致），整通电话期间不切换归属。
## Requirements
### Requirement: 触发场景白名单

垫词 SHALL 仅在常规对话 PROCESSING 状态下播放；其他状态 MUST NOT 播放。

#### Scenario: 常规对话 PROCESSING 触发

- **WHEN** 用户说完话进入常规 PROCESSING
- **THEN** engine SHALL 同时启动 AI 管线和垫词播放

#### Scenario: 开场白后第 1 轮 PROCESSING 不播

- **WHEN** GREETING 播完后用户首次说话进入 PROCESSING
- **THEN** engine MUST NOT 播放垫词

#### Scenario: WRAPPING_UP 期间 PROCESSING 不播

- **WHEN** 收尾模式下进入简化管线
- **THEN** engine MUST NOT 播放垫词

#### Scenario: 转人工 / 沉默激活 / 收尾告别 不播

- **WHEN** 处于 TRANSFERRING / ACTIVATING 或播放 wrap_up_closing_phrases / silence_hangup_phrase
- **THEN** engine MUST NOT 播放垫词

### Requirement: 启动时机与衔接

垫词 SHALL 与 AI 管线**同时**启动（不等管线返回），TTS 准备好后 engine MUST 等垫词播完再接 reply。

#### Scenario: 管线先于垫词返回

- **WHEN** AI 管线在垫词播放期间产出 reply 并 TTS 流准备好
- **THEN** engine SHALL 等垫词播完，立即接 reply 的 TTS

#### Scenario: 快响应场景

- **WHEN** AI 管线 < 500ms 即返回
- **THEN** engine 仍 SHALL 播完整段垫词再接 reply（保证节奏一致，不因偶发快响应而打破稳定的对话节拍）

#### Scenario: 垫词期间被打断

- **WHEN** 垫词 TTS 播放中 ASR 中间结果触发"打断"判定
- **THEN** engine MUST 立即停止垫词、丢弃当前 PROCESSING 中的 AI 管线，把用户输入作为新一轮处理

### Requirement: 失败兜底允许无声延迟

任何垫词失败场景 SHALL 跳过垫词、直接等 reply；engine MUST NOT 引入"万能兜底垫词"。

#### Scenario: 短语文本为空

- **WHEN** `campaign.filler_phrases` 中某条文本为空白
- **THEN** engine 跳过该条，从其余非空文本随机抽；池中无任何非空文本则直接等待管线返回 reply

#### Scenario: 实时合成异常

- **WHEN** 垫词 TTS 实时合成或推流过程抛异常
- **THEN** engine 记录日志并跳过本次垫词，直接等待 reply（允许"无声延迟"），MUST NOT 中断通话

#### Scenario: 垫词池无可用文本

- **WHEN** `campaign.filler_phrases` 为空或全是空白字符串
- **THEN** engine 跳过垫词，整通通话不再尝试垫词

### Requirement: filler（垫词）时间门控播放

filler MUST NOT 在每轮 PROCESSING 入口无条件立即播放。当 `filler_enabled` 为真时，engine SHALL 仅在**首音频迟迟未出**时才播垫词。

计时锚点 SHALL 为 **PROCESSING 进入时刻**（`processing_start`，即 engine 判定客户说完话、转入常规 PROCESSING 的那一刻），而 **MUST NOT** 是门控/referee 投票之后、`_play_streaming` 进入的时刻。自该锚点起一个 `filler_delay_ms`（默认 600，campaign 可调）的计时预算，若到时主回复的第一句音频仍未开始播放，则播放一句垫词以遮住等待；一旦主回复第一句就绪，engine MUST 取消该计时器并停止任何在播垫词，无缝接上主回复。

门控/referee 投票、ASR finalize 等"客户已说完话、但 AI 尚未出声"的内部等待期间 SHALL **计入** `filler_delay_ms` 预算——即 `filler_delay_ms` 是"自客户说完话起、AI 仍无任何音频"的客户可感知静默上限，而非门控之后才另起的二段延迟。因此若进入播音阶段时该预算已耗尽（首音频仍未出），engine SHALL **立即**播垫词，MUST NOT 再额外等满一个 `filler_delay_ms`。

垫词音频 SHOULD 走 TTS 缓存（命中零合成），以使垫词本身不引入额外合成延迟——否则垫词起不到遮延迟的作用。

#### Scenario: 快轮次不播垫词

- **WHEN** 主回复第一句音频在自 PROCESSING 进入起 `filler_delay_ms` 内就绪
- **THEN** engine MUST NOT 播放垫词（计时器被取消）；该轮干净，无垫词污染

#### Scenario: 慢轮次播缓存垫词遮空档

- **WHEN** 自 PROCESSING 进入起 `filler_delay_ms` 到时、主回复第一句音频仍未出
- **THEN** engine SHALL 播放一句垫词（音频走缓存、零合成）遮住等待；主回复第一句就绪时停垫词并接上

#### Scenario: 门控耗时已超预算则进入播音即刻插垫词

- **WHEN** 门控/referee 投票 + ASR finalize 等内部等待耗时已 ≥ `filler_delay_ms`，且进入 `_play_streaming` 时主回复第一句音频仍未出
- **THEN** engine SHALL 立即播垫词，MUST NOT 在门控之后再额外等满一个 `filler_delay_ms`

#### Scenario: filler 关闭时无行为

- **WHEN** `filler_enabled` 为假
- **THEN** engine MUST NOT 起垫词计时器、MUST NOT 播垫词

### Requirement: 垫词池随机不重复

每通电话 SHALL 在 call_session 内存态维护单个已用短语集合（`used_filler_phrases`，按**文本**去重）；同一通电话 MUST NOT 重复使用同一条垫词文本，直至该 campaign 垫词池（`campaign.filler_phrases`，一个 `list[str]`）内全部文本用完后清空记录、重新可选。垫词池无分组、无顺序。

#### Scenario: 同一通电话不重复

- **WHEN** 第 1 轮 PROCESSING 使用了池中的「让我看一下」，后续轮次再次触发垫词
- **THEN** engine SHALL 从池中除已用文本之外随机抽 1；池中无未用文本时清空已用记录再随机抽

#### Scenario: 池内全部用过后重置

- **WHEN** 本通电话已用尽 campaign 垫词池内全部文本
- **THEN** engine SHALL 清空该通电话的已用记录，下一轮从全部文本中重新随机抽取

### Requirement: 运行时合成垫词音频

垫词文本存于 `campaign.filler_phrases`（JSONB `list[str]`，与 `silence_phrases` / `interruption_whitelist` 同范式，无独立 `filler_phrase` 表）。v1.0 垫词音频 SHALL 在运行时由 engine 用 Campaign 配置的音色实时 TTS 合成被选中的垫词文本，并 SHALL 经进程级缓存（同 `(text, voice_id)` 命中后零重复合成）降低延迟。垫词 MUST NOT 保留 `audio_url` / `generation_status` 等预录字段——若未来引入 OSS 预录，SHALL 由独立 change 重新设计承载结构，本规范 MUST NOT 预留死字段。

#### Scenario: 运行时实时合成可用文本

- **WHEN** 进入常规对话 PROCESSING 且垫词被时间门控触发
- **THEN** engine SHALL 从 `campaign.filler_phrases` 中选 1 条非空文本，用 Campaign 音色实时 TTS 合成并播放

#### Scenario: 进程缓存命中零重复合成

- **WHEN** 同一 `(垫词文本, voice_id)` 在本进程内再次被选中
- **THEN** engine SHALL 复用缓存的 PCM，MUST NOT 重新调用 TTS

## Data Schema

```
campaign
  └─ filler_phrases           ← JSONB list[str]：扁平垫词池，随 campaign 行存
                                （与 silence_phrases / interruption_whitelist 同范式）

（无独立 filler_phrase 表；无 per-phrase id / audio_url / generation_status。
 未来若上 OSS 预录，由独立 change 重新设计承载结构。）
```
