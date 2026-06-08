## ADDED Requirements

### Requirement: campaign.filler_delay_ms 垫词门控阈值

`campaign` 表 SHALL 含 `filler_delay_ms`（INT，nullable）字段，表示进入 PROCESSING 后多久（毫秒）首音频仍未出就播垫词。NULL MUST 走系统默认（600ms）。engine `load_runtime_config` SHALL 读出该值透传给 `_play_streaming` 的垫词门控计时器。

#### Scenario: NULL 走默认

- **WHEN** campaign `filler_delay_ms IS NULL`
- **THEN** engine SHALL 用系统默认 600ms 作为垫词门控阈值

#### Scenario: campaign 覆盖

- **WHEN** campaign `filler_delay_ms = 400`
- **THEN** engine SHALL 在首音频超过 400ms 未出时播垫词
