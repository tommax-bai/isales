## Purpose

垫词在 AI 管线处理期间播放，用于覆盖 LLM/TTS 延迟。本规范定义触发场景、启动时机、选择策略、音频来源、失败兜底与数据模型。垫词配置 MUST 绑定在 Campaign 级（与音色一致），整通电话期间不切换归属。

## Requirements

### Requirement: 触发场景白名单

垫词 SHALL 仅在常规对话 PROCESSING 状态下播放；其他状态 MUST NOT 播放。

#### Scenario: 常规对话 PROCESSING 触发

- **WHEN** 用户说完话进入常规 PROCESSING
- **THEN** engine SHALL 同时启动 AI 管线和垫词播放

#### Scenario: 开场白后第 1 轮 PROCESSING 不播

- **WHEN** GREETING 播完后用户首次说话进入 PROCESSING
- **THEN** engine MUST NOT 播放垫词

#### Scenario: WRAPPING_UP 期间 PROCESSING 不播

- **WHEN** 收尾模式下进入简化管线
- **THEN** engine MUST NOT 播放垫词

#### Scenario: 转人工 / 沉默激活 / 收尾告别 不播

- **WHEN** 处于 TRANSFERRING / ACTIVATING 或播放 wrap_up_closing_phrases / silence_hangup_phrase
- **THEN** engine MUST NOT 播放垫词

### Requirement: 启动时机与衔接

垫词 SHALL 与 AI 管线**同时**启动（不等管线返回），TTS 准备好后 engine MUST 等垫词播完再接 reply。

#### Scenario: 管线先于垫词返回

- **WHEN** AI 管线在垫词播放期间产出 reply 并 TTS 流准备好
- **THEN** engine SHALL 等垫词播完，立即接 reply 的 TTS

#### Scenario: 快响应场景

- **WHEN** AI 管线 < 500ms 即返回
- **THEN** engine 仍 SHALL 播完整段垫词再接 reply（保证节奏一致，不因偶发快响应而打破稳定的对话节拍）

#### Scenario: 垫词期间被打断

- **WHEN** 垫词 TTS 播放中 ASR 中间结果触发"打断"判定
- **THEN** engine MUST 立即停止垫词、丢弃当前 PROCESSING 中的 AI 管线，把用户输入作为新一轮处理

### Requirement: 多 filler_set 轮询

Campaign 关联多个 `filler_set`（集合）。engine SHALL 按 `sort_order` 字段升序依次使用，到末尾后从头循环。每通电话开始时从 `sort_order` 最小的 set 起步。

#### Scenario: 三个集合的轮询顺序

- **WHEN** Campaign 配 3 个 filler_set 且本通电话进入第 4 轮 PROCESSING
- **THEN** 第 1 轮用 set#1、第 2 轮 set#2、第 3 轮 set#3、第 4 轮重新回 set#1

#### Scenario: 多 filler_set 不区分语义类型

- **WHEN** 配置垫词集合
- **THEN** 系统 MUST NOT 引入 thinking/confirming/casual 等场景标签；多 set 仅作为分组与轮询单元

### Requirement: 集合内随机不重复

每通电话 SHALL 在 call_session 内存态维护已用短语集合；同一通电话 MUST NOT 重复使用同一短语，直至该 set 内全部短语用完后清空记录。

#### Scenario: 第 4 轮命中 set#1 时避免重复

- **WHEN** 第 1 轮使用了 set#1 中的「让我看一下」，第 4 轮再次轮到 set#1
- **THEN** 第 4 轮 SHALL 从 set#1 中除「让我看一下」之外的短语随机抽 1

#### Scenario: 集内全部用过后重置

- **WHEN** 某 set 内全部短语在本通电话中都已使用过
- **THEN** engine SHALL 清空该 set 的已用记录，下一轮命中该 set 时从全部短语中重新抽取

### Requirement: 预生成 + 动态补充音频

垫词音频 SHALL 在拨打前由 worker 预先用 Campaign 配置的音色 TTS 生成并存储到 OSS。运行时 MUST NOT 实时调用 TTS 生成垫词。

#### Scenario: 新增垫词触发预生成

- **WHEN** 用户在 isales-web 新增或编辑 filler_phrase
- **THEN** worker 后台任务 `regenerate_filler_audio` 入队，生成完成后写 `filler_phrase.audio_url` 并置 `generation_status=ready`

#### Scenario: Campaign 切换音色级联

- **WHEN** Campaign 切换 voice_model
- **THEN** 该 Campaign 所属全部 filler_phrase MUST 重新触发预生成

### Requirement: 失败兜底允许无声延迟

任何垫词失败场景 SHALL 跳过垫词、直接等 reply；engine MUST NOT 引入"万能兜底垫词"。

#### Scenario: 预生成未完成

- **WHEN** 新建 Campaign 立即拨打且 filler_phrase 仍处于 `generation_status=pending`
- **THEN** engine 跳过垫词，直接等待管线返回 reply

#### Scenario: 音频文件下载失败

- **WHEN** OSS 下载垫词音频失败
- **THEN** engine 跳过垫词，直接等待 reply（允许"无声延迟"）

#### Scenario: 全部 filler_set 都没有可用音频

- **WHEN** 该 Campaign 下所有 filler_phrase 均未 ready
- **THEN** engine 跳过垫词，整通通话不再尝试垫词

## Data Schema

```
campaign
  └─ (无 filler_set_id；改由 filler_set.campaign_id 反向关联，1:n)

filler_set
  ├─ id
  ├─ campaign_id
  ├─ name
  ├─ sort_order               ← 轮询顺序
  └─ created_at / updated_at

filler_phrase
  ├─ id
  ├─ filler_set_id
  ├─ phrase                   ← 文本
  ├─ audio_url                ← OSS 路径（可空，待预生成）
  ├─ generation_status        ← pending / ready / failed
  └─ created_at / updated_at
```
