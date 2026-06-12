## MODIFIED Requirements

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
