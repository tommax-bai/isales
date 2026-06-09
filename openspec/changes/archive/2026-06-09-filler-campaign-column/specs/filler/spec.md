## RENAMED Requirements

- FROM: `### Requirement: 预生成 + 动态补充音频`
- TO: `### Requirement: 运行时合成垫词音频`

## MODIFIED Requirements

### Requirement: 垫词池随机不重复

每通电话 SHALL 在 call_session 内存态维护单个已用短语集合（`used_filler_phrases`，按**文本**去重）；同一通电话 MUST NOT 重复使用同一条垫词文本，直至该 campaign 垫词池（`campaign.filler_phrases`，一个 `list[str]`）内全部文本用完后清空记录、重新可选。垫词池无分组、无顺序。

#### Scenario: 同一通电话不重复

- **WHEN** 第 1 轮 PROCESSING 使用了池中的「让我看一下」，后续轮次再次触发垫词
- **THEN** engine SHALL 从池中除已用文本之外随机抽 1；池中无未用文本时清空已用记录再随机抽

#### Scenario: 池内全部用过后重置

- **WHEN** 本通电话已用尽 campaign 垫词池内全部文本
- **THEN** engine SHALL 清空该通电话的已用记录，下一轮从全部文本中重新随机抽取

### Requirement: 运行时合成垫词音频

垫词文本存于 `campaign.filler_phrases`（JSONB `list[str]`，与 `silence_phrases` / `interruption_whitelist` 同范式，无独立 `filler_phrase` 表）。v1.0 垫词音频 SHALL 在运行时由 engine 用 Campaign 配置的音色实时 TTS 合成被选中的垫词文本，并 SHALL 经进程级缓存（同 `(text, voice_id)` 命中后零重复合成）降低延迟。垫词 MUST NOT 保留 `audio_url` / `generation_status` 等预录字段——若未来引入 OSS 预录，SHALL 由独立 change 重新设计承载结构，本规范 MUST NOT 预留死字段。

#### Scenario: 运行时实时合成可用文本

- **WHEN** 进入常规对话 PROCESSING 且垫词被时间门控触发
- **THEN** engine SHALL 从 `campaign.filler_phrases` 中选 1 条非空文本，用 Campaign 音色实时 TTS 合成并播放

#### Scenario: 进程缓存命中零重复合成

- **WHEN** 同一 `(垫词文本, voice_id)` 在本进程内再次被选中
- **THEN** engine SHALL 复用缓存的 PCM，MUST NOT 重新调用 TTS

### Requirement: 失败兜底允许无声延迟

任何垫词失败场景 SHALL 跳过垫词、直接等 reply；engine MUST NOT 引入"万能兜底垫词"。

#### Scenario: 短语文本为空

- **WHEN** `campaign.filler_phrases` 中某条文本为空白
- **THEN** engine 跳过该条，从其余非空文本随机抽；池中无任何非空文本则直接等待管线返回 reply

#### Scenario: 实时合成异常

- **WHEN** 垫词 TTS 实时合成或推流过程抛异常
- **THEN** engine 记录日志并跳过本次垫词，直接等待 reply（允许"无声延迟"），MUST NOT 中断通话

#### Scenario: 垫词池无可用文本

- **WHEN** `campaign.filler_phrases` 为空或全是空白字符串
- **THEN** engine 跳过垫词，整通通话不再尝试垫词
