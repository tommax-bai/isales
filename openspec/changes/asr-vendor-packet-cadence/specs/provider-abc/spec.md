## ADDED Requirements

### Requirement: ASR Provider 向 vendor 发包遵守 vendor 粒度规格

ASR Provider 的实现在向上游 vendor（流式语音识别服务）发送音频时，MUST 按 vendor 文档规定的单包大小与发包间隔成批发送，MUST NOT 把上游音频源（如 RTC 的 10ms 帧）以远小于规格的粒度逐帧 1:1 转发。

当 vendor 通过静音判停参数（如 `end_window_size`）切句时，发包粒度违规会使该判停形同失效：vendor 把整句 `definite`/最终结果的 finalize 拖到数秒级，并可能触发 vendor 侧的 keepalive/ping 超时而频繁重连。因此 Provider SHALL 在发送前累积到 vendor 推荐的包时长（量级 100–200ms），使每轮用户语音的最终结果 finalize 尾延迟落在亚秒级。

发包粒度是 Provider 与 vendor 之间的实装契约，MUST NOT 因上游音频帧大小变化而违反；上游帧更小时，Provider MUST 在内部缓冲攒包。

#### Scenario: 上游 10ms 帧攒包后再发给 vendor

- **WHEN** 上游以 10ms 一帧的粒度向 ASR Provider 持续推送 PCM
- **THEN** Provider MUST 在内部累积到 vendor 推荐的包时长（~100–200ms）后再发送一包，MUST NOT 每个 10ms 帧各发一包

#### Scenario: 用户说完一句后及时 finalize

- **WHEN** 用户说完一句、随后进入静音，且 vendor 配置了静音判停（`end_window_size`）
- **THEN** vendor SHALL 在亚秒级（与 `end_window_size` 同量级，而非数秒）输出该句的最终结果（`is_final=true` / `definite=true`），使引擎能及时进入下一轮；MUST NOT 因发包过碎而把 finalize 拖到 5–11 秒

### Requirement: ASR 输入静音整形不污染打断检测路径

当引擎为了让 vendor 的静音判停及时触发，而对喂给 ASR 的音频做静音整形（如把句末低能量帧替换为数字静音）时，该整形 MUST 仅作用于喂 ASR vendor 的音频路径，MUST NOT 作用于喂打断检测（barge-in / `interruption-detection`）的音频路径——后者需要原始未整形的信号来判定用户插话。

静音整形 SHALL 带迟滞 / hangover，避免把一句话内部的自然停顿误整形为句末静音而导致 vendor 半句 finalize（碎句）。整形阈值与 hangover SHALL 可配置。

#### Scenario: ASR 路喂静音、VAD 路喂原始

- **WHEN** 引擎对入站音频做句末静音整形以辅助 vendor 判停
- **THEN** 喂 ASR vendor 的那一路 MAY 在句末连续低能量超过 hangover 后被替换为数字静音；喂打断检测的那一路 MUST 始终是原始音频

#### Scenario: 句内停顿不被整形成句末静音

- **WHEN** 用户一句话中间有短暂自然停顿（低于 hangover 时长）
- **THEN** 静音整形 MUST NOT 在该停顿处喂数字静音；MUST NOT 导致 vendor 在句中提前 finalize 产生碎句
