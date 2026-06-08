## ADDED Requirements

### Requirement: TTSProvider 固定话术缓存

引擎 SHOULD 提供一个缓存层（如装饰 `TTSProvider` 的 `CachingTTSProvider`），对**固定/可复用文本**的 `synthesize_stream(text, voice_id)` 命中即重放已存 PCM，零合成、零网络。缓存 MUST 对正确性透明：命中重放的音频与现合成等价；未命中 MUST 透传 inner provider 并在完整成功后填充缓存。

缓存 MUST 有界（条数 / 总字节上限，LRU 淘汰），MUST NOT 无界增长。缓存键 MUST 含 `voice_id`（换音色自然 miss）。实装 SHOULD 用文本长度阈值区分固定话术（短、缓存）与动态回复（长、不缓存），避免缓存动态 main 回复。缓存 MUST NOT 在合成中途异常 / 被打断时写入（避免半截污染）。

#### Scenario: 固定话术命中零合成

- **WHEN** 同一 `(text, voice_id)` 的固定话术（如开场白）在缓存暖后再次合成
- **THEN** provider SHALL 直接重放已存 PCM，MUST NOT 再发 TTS 合成请求 / 付网络与首字节延迟

#### Scenario: 未命中透传并填充

- **WHEN** `(text, voice_id)` 不在缓存且文本长度在可缓存阈值内
- **THEN** provider SHALL 透传 inner 合成、边播边累积，并在 iterator 完整成功后写入缓存；下次同键命中

#### Scenario: 动态长文本不缓存

- **WHEN** 文本长度超过可缓存阈值（如动态 main LLM 回复）
- **THEN** provider SHALL 直接透传 inner 合成，MUST NOT 写入缓存
