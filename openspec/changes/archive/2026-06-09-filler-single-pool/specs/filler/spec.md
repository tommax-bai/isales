## REMOVED Requirements

### Requirement: 多 filler_set 轮询

**Reason**: `filler_set` 分组层被删除（`filler_phrase` 直挂 `campaign`），跨组按 `sort_order` 轮询的语义随之消失。spec 原本就规定多 set 不携带任何语义（仅分组与轮询单元），故合并入单池不丢业务信息。

**Migration**: 多组 campaign 的全部 `filler_phrase` 合并进同一 campaign 垫词池；选词改由「垫词池随机不重复」单条 Requirement 描述。

## RENAMED Requirements

- FROM: `### Requirement: 集合内随机不重复`
- TO: `### Requirement: 垫词池随机不重复`

## MODIFIED Requirements

### Requirement: 垫词池随机不重复

每通电话 SHALL 在 call_session 内存态维护单个已用短语 id 集合（`used_filler_phrase_ids`）；同一通电话 MUST NOT 重复使用同一 `filler_phrase`，直至该 campaign 垫词池内全部短语用完后清空记录、重新可选。垫词池 = 该 campaign 下全部 `filler_phrase`，无分组、无顺序。

#### Scenario: 同一通电话不重复

- **WHEN** 第 1 轮 PROCESSING 使用了池中的「让我看一下」，后续轮次再次触发垫词
- **THEN** engine SHALL 从池中除已用短语之外随机抽 1；池中无未用短语时清空已用记录再随机抽

#### Scenario: 池内全部用过后重置

- **WHEN** 本通电话已用尽 campaign 垫词池内全部短语
- **THEN** engine SHALL 清空该通电话的已用记录，下一轮从全部短语中重新随机抽取

### Requirement: 失败兜底允许无声延迟

任何垫词失败场景 SHALL 跳过垫词、直接等 reply；engine MUST NOT 引入"万能兜底垫词"。

#### Scenario: 短语文本为空

- **WHEN** campaign 垫词池内某短语 `phrase` 文本为空
- **THEN** engine 跳过该短语，从池中其余非空短语随机抽；池中无任何非空文本短语则直接等待管线返回 reply

#### Scenario: 实时合成异常

- **WHEN** 垫词 TTS 实时合成或推流过程抛异常
- **THEN** engine 记录日志并跳过本次垫词，直接等待 reply（允许"无声延迟"），MUST NOT 中断通话

#### Scenario: 垫词池无可用文本

- **WHEN** 该 campaign 下所有 filler_phrase 文本均为空
- **THEN** engine 跳过垫词，整通通话不再尝试垫词
