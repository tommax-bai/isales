## MODIFIED Requirements

### Requirement: TTS Provider 异步流式合成接口

TTSProvider SHALL 暴露异步流式合成接口：输入文本与音色，输出 PCM 音频字节流（首包尽快返回以降低端到端延迟）。

#### Scenario: 流式输出首包

- **WHEN** 调用 `synthesize_stream(text, voice_id)`
- **THEN** 接口 MUST 以 `AsyncIterator[bytes]` 返回 PCM chunks；首包 SHALL 在 500ms 内开始返回（依赖供应商能力，ABC 不强制超时但实现应自测）

#### Scenario: 音色由 voice_id 选择

- **WHEN** 调用合成
- **THEN** 调用方 SHALL 传入 `campaign.voice_id`——一个不透明的 vendor speaker 标识字符串（如 `zh_female_xiaohe_uranus_bigtts`），原样透传给 TTS provider；该字符串不在本系统编目（`voice_model` 表已随 `admin-prune-vestigial-features` 删除），ABC 不关心 voice_id 的内部映射；`voice_id` 为空时实现 MAY 回落到 provider 默认音色
