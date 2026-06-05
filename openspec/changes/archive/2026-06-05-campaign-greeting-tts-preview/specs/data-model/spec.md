## ADDED Requirements

### Requirement: campaign.voice_id 持有 vendor speaker 字符串

`campaign.voice_id` SHALL 为 `String(128)`、可空，直接持有 TTS vendor 的 speaker 标识字符串（如 `zh_female_xiaohe_uranus_bigtts`），由管理员在场景表单填写。该列 MUST NOT 是指向 `voice_model` 的外键——音色不在本系统编目，引擎与试听端点都将该字符串原样传给 TTS provider。NULL / 空串表示使用 provider 默认音色。

#### Scenario: 存取 speaker 字符串

- **WHEN** 创建 / 更新 campaign 时提供 `voice_id`（vendor speaker 串）
- **THEN** 系统 MUST 原样持久化该字符串，读取时原样返回，引擎合成时直接用作 TTS speaker

#### Scenario: 不依赖 voice_model 编目

- **WHEN** 设置 campaign 的音色
- **THEN** 系统 MUST NOT 要求该 speaker 预先存在于 `voice_model` 表；`campaign.voice_id` MUST NOT 对 `voice_model` 施加外键约束
