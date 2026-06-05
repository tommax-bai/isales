## ADDED Requirements

### Requirement: 引擎按 campaign 指定音色合成

引擎合成所有播音（开场白 + 主链路回复 + 固定话术）时 SHALL 使用 campaign 指定的音色。`campaign.voice_id` 持有 vendor speaker 字符串（如 `zh_female_xiaohe_uranus_bigtts`，由管理员在场景表单直接填写），引擎 MUST 将其原样传给 TTS provider 作为 speaker。`campaign.voice_id` 为 NULL / 空串时 MUST 回落到 provider 的默认 speaker，MUST NOT 让整通电话失败。

#### Scenario: 指定音色被真实通话消费

- **WHEN** campaign 的 `voice_id` 为一个非空 vendor speaker 串并发起通话
- **THEN** 引擎 MUST 用该串作为 TTS speaker 合成播音，使真实通话的发音与 web 端「试听」一致

#### Scenario: 未指定音色回落默认

- **WHEN** campaign 的 `voice_id` 为 NULL 或空串
- **THEN** 引擎 MUST 用 provider 默认 speaker 合成，通话正常进行，MUST NOT 抛错中断
