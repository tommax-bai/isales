## MODIFIED Requirements

### Requirement: 预生成 + 动态补充音频

v1.0 垫词音频 SHALL 在运行时由 engine 用 Campaign 配置的音色实时 TTS 合成 `filler_phrase.phrase` 文本，并 SHALL 经进程级缓存（同 `(text, voice_id)` 命中后零重复合成）降低延迟。垫词选取 MUST NOT 依赖 `filler_phrase.audio_url` 非空或 `generation_status == ready`——这两个字段属 stage-6 OSS 预录路径，v1.0 无 OSS / 无预生成 worker 时恒为空，若作为选取门槛会使垫词永不触发。

stage-6（OSS + `regenerate_filler_audio` worker 落地后）SHALL 以独立 change 恢复「`audio_url` 就绪则直接推流、否则实时合成」的优先分支；在该 worker + OSS 就绪前 MUST NOT 提前引入该双分支（避免纯死代码与多层 fallback）。

#### Scenario: 运行时实时合成可用文本

- **WHEN** 进入常规对话 PROCESSING 且垫词被时间门控触发
- **THEN** engine SHALL 从可用 filler_phrase 中选 1（判据为 `phrase` 文本非空），用 Campaign 音色实时 TTS 合成并播放，MUST NOT 因 `audio_url` 为空或 `generation_status=pending` 而跳过

#### Scenario: 进程缓存命中零重复合成

- **WHEN** 同一 `(垫词文本, voice_id)` 在本进程内再次被选中
- **THEN** engine SHALL 复用缓存的 PCM，MUST NOT 重新调用 TTS

#### Scenario: stage-6 OSS 预生成为可选优化

- **WHEN** 未来 OSS + `regenerate_filler_audio` worker 落地
- **THEN** 可由独立 change 恢复 `audio_url` 优先推流分支；在此之前运行时实时合成是唯一主路径

### Requirement: 失败兜底允许无声延迟

任何垫词失败场景 SHALL 跳过垫词、直接等 reply；engine MUST NOT 引入"万能兜底垫词"。

#### Scenario: 短语文本为空

- **WHEN** 某 filler_set 内短语 `phrase` 文本均为空
- **THEN** engine 跳过该 set，尝试下一个；无可用文本则直接等待管线返回 reply

#### Scenario: 实时合成异常

- **WHEN** 垫词 TTS 实时合成或推流过程抛异常
- **THEN** engine 记录日志并跳过本次垫词，直接等待 reply（允许"无声延迟"），MUST NOT 中断通话

#### Scenario: 全部 filler_set 都没有可用文本

- **WHEN** 该 Campaign 下所有 filler_phrase 文本均为空
- **THEN** engine 跳过垫词，整通通话不再尝试垫词
