## ADDED Requirements

### Requirement: 引擎按 campaign 选定音色合成

引擎合成所有播音（开场白 + 主链路回复 + 固定话术）时 SHALL 使用 campaign 选定的音色。`campaign.voice_id` 是 `VoiceModel` 外键；引擎 MUST 将其解析为 `VoiceModel.voice_id`（vendor speaker 串）再传给 TTS provider。未选音色（NULL）或对应 VoiceModel 不存在时 MUST 回落到 provider 的默认 speaker，MUST NOT 让整通电话失败。

#### Scenario: 选定音色被真实通话消费

- **WHEN** campaign 设置了有效的 `voice_id`（指向一条 VoiceModel）并发起通话
- **THEN** 引擎 MUST 用该 VoiceModel 的 vendor speaker 串合成播音，使真实通话的发音与 web 端「试听」一致

#### Scenario: 未选音色回落默认

- **WHEN** campaign 的 `voice_id` 为 NULL，或其指向的 VoiceModel 行不存在
- **THEN** 引擎 MUST 用 provider 默认 speaker 合成，通话正常进行，MUST NOT 抛错中断
