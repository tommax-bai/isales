## ADDED Requirements

### Requirement: 出向常驻混音泵持续推帧

引擎 SHALL 为每通已接通的通话运行一个常驻出向混音泵（continuous outbound mixing pump）。泵 SHALL 在通话存续期间按固定 10ms 帧间隔持续向 DingRTC 推送出向音频帧（16kHz、mono、int16、每帧 160 samples），无论 AI 是否正在说话。泵 SHALL 在通话接通后启动、在挂断或离开 RTC 房间时停止。

#### Scenario: 静默期仍持续推帧

- **WHEN** 通话处于无 TTS 播放的静默期（句间空档或等待客户说话）
- **THEN** 泵 SHALL 继续以 10ms 间隔推送出向帧，帧内容为背景环境音（若已启用）或静音帧（若未启用）
- **AND** 出向时间戳 SHALL 连续递增，不因无 TTS 而暂停或跳跃

#### Scenario: TTS 播放期叠加背景音

- **WHEN** 出向播放队列（playout queue）中存在已合成的 TTS PCM
- **THEN** 泵 SHALL 取出一帧 TTS PCM 与一帧背景音逐样本相加，并对结果做 int16 削顶（clip）保护后推送

### Requirement: TTS 经播放队列驱动，合成不受影响

TTS 播放路径 SHALL 把已合成的 PCM 切成 10ms 帧写入出向播放队列（playout queue），而非直接调用 DingRTC 推帧接口。出向混音泵 SHALL 是唯一调用 DingRTC `push_external_audio` 的组件。TTS 合成的输入 SHALL 仍为整句文本，本变更 SHALL NOT 改变句子切分或合成请求的粒度。

#### Scenario: 合成粒度不变

- **WHEN** 引擎对一段回复做 TTS 合成
- **THEN** 句子切分（按终止符与字符上限）与每句一个合成请求的行为 SHALL 与本变更前一致
- **AND** 10ms 切帧 SHALL 仅发生在合成完成后的出向推帧侧

### Requirement: 背景音素材循环播放

启用背景音的通话，引擎 SHALL 将背景音素材预处理为 16kHz mono int16 并加载为可循环读取的缓冲。泵 SHALL 在该缓冲上循环读取（读到末尾回绕到开头）形成无限 loop，并 SHALL 在回绕接缝处做平滑处理以避免可听爆音。`ambient_gain` SHALL 控制背景音混入的电平。

#### Scenario: 素材播放到末尾回绕

- **WHEN** 背景音读指针到达素材缓冲末尾
- **THEN** 泵 SHALL 回绕到缓冲开头继续读取，使背景音不间断
- **AND** 回绕接缝 SHALL 经平滑处理不产生可听爆音

#### Scenario: 未配置背景音时等价现状

- **WHEN** campaign 的 `ambient_audio` 为空或未配置
- **THEN** 泵推送的帧 SHALL 仅含 TTS 音频或静音，背景音分量为零
- **AND** 客户侧听感 SHALL 与本变更前一致

### Requirement: 打断后背景音延续

当发生 barge-in 打断时，引擎 SHALL 清空出向播放队列（丢弃未播的 TTS 帧）以立即停止 AI 语音输出，而泵 SHALL 继续推送背景音帧。打断 SHALL NOT 导致出向完全静音。

#### Scenario: 打断时语音停、背景音续

- **WHEN** 客户打断且引擎决定停止当前播放
- **THEN** 引擎 SHALL 清空 playout queue 使 AI 语音立即停止
- **AND** 泵 SHALL 在下一帧起继续推送背景音（若启用），出向不出现死寂

### Requirement: 背景音与入向断句隔离（硬不变量）

背景音混音 SHALL 只发生在出向（engine → 客户）音频路径。本变更 SHALL NOT 修改入向（客户 → engine）音频路径、ASR finalize（断句）逻辑或 barge-in 检测逻辑的任何代码。背景音 SHALL NOT 被混入引擎送往 ASR 的音频。

#### Scenario: 入向路径零改动

- **WHEN** 启用背景音的通话进行 ASR 识别与断句
- **THEN** 送往 ASR 的入向音频 SHALL 不含引擎注入的背景音
- **AND** 断句（finalize）与 barge-in 检测行为 SHALL 仅由客户入向音频决定

### Requirement: 出向配速稳定

泵 SHALL 使用单调时钟驱动配速，并 SHALL 依据"应到帧数 vs 已推帧数"补齐或等待，以避免累积时间漂移。泵 SHALL 将 DingRTC SDK 抖动缓冲维持在安全水位，既不溢出（推帧失败）也不欠载（卡顿/变调）。

#### Scenario: 配速不漂移

- **WHEN** 通话持续数分钟
- **THEN** 累计推送帧数 SHALL 与墙钟经过时间对应（每 10ms 一帧），不出现持续提前或滞后
- **AND** 客户侧 SHALL NOT 听到因配速漂移导致的 TTS 变调或卡顿
