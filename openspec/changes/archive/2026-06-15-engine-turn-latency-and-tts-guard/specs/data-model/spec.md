## ADDED Requirements

### Requirement: pipeline_trace 首 token / 首句延迟列

`pipeline_trace` SHALL 新增两列承载 main LLM 的细粒度首字延迟:`main_first_token_ms`(int,可空,从 main 生成起到 LLM 首个 token)、`main_first_sentence_ms`(int,可空,到首个可切句送 TTS)。二者与既有 `main_duration_ms`(末 token)、`first_audio_ms`(首 PCM 播放)共同构成单轮「LLM 收到 → 用户端播放」的逐节点延迟分解。新增列 MUST 可空(历史行 + fallback / 无 token 轮为 NULL),MUST NOT 破坏既有读路径。

#### Scenario: 新列可空且不破坏读

- **WHEN** 迁移在既有 `pipeline_trace` 上加 `main_first_token_ms` / `main_first_sentence_ms`
- **THEN** 历史行该两列 SHALL 为 NULL;`call_record` 读路径(transcript)不受影响;downgrade SHALL drop 两列
