## ADDED Requirements

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
