## MODIFIED Requirements

### Requirement: filler（垫词）时间门控播放

filler MUST NOT 在每轮 PROCESSING 入口无条件立即播放。当 `filler_enabled` 为真时，engine SHALL 仅在**首音频迟迟未出**时才播垫词：进入 PROCESSING 后起一个 `filler_delay_ms`（默认 600，campaign 可调）的计时器，若到时主回复的第一句音频仍未开始播放，则播放一句垫词以遮住等待；一旦主回复第一句就绪，engine MUST 取消该计时器并停止任何在播垫词，无缝接上主回复。

垫词音频 SHOULD 走 TTS 缓存（命中零合成），以使垫词本身不引入额外合成延迟——否则垫词起不到遮延迟的作用。

#### Scenario: 快轮次不播垫词

- **WHEN** 主回复第一句音频在 `filler_delay_ms` 内就绪
- **THEN** engine MUST NOT 播放垫词（计时器被取消）；该轮干净，无垫词污染

#### Scenario: 慢轮次播缓存垫词遮空档

- **WHEN** 进入 PROCESSING 后 `filler_delay_ms` 到时、主回复第一句音频仍未出
- **THEN** engine SHALL 播放一句垫词（音频走缓存、零合成）遮住等待；主回复第一句就绪时停垫词并接上

#### Scenario: filler 关闭时无行为

- **WHEN** `filler_enabled` 为假
- **THEN** engine MUST NOT 起垫词计时器、MUST NOT 播垫词
