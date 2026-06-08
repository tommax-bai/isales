## ADDED Requirements

### Requirement: ASR 连接在 AI 说话期间保持可用

ASR 流式连接 MUST 在 AI 处于 SPEAKING / FILLER（播放 TTS）期间保持可用，以便实时打断检测（`_partial_monitor`）能在 AI 说话时收到用户的 partial 识别结果。上一轮用户说话结束（EOS）后主动关闭 ASR 连接是允许的（用于跳过 vendor 慢 finalize），但该关闭 MUST NOT 阻塞下一次重连——重连 SHALL 在 EOS 后尽快完成（量级 ~数百毫秒），MUST NOT 因等待 vendor 的关闭握手而阻塞到秒级，否则会在 AI 整轮说话期间使 ASR 失聪、barge-in 无法触发。

具体到 WebSocket 实装：连接 MUST 配置一个短的关闭超时（close handshake 等待上限），MUST NOT 使用会阻塞到 ~10s 的库默认值。

#### Scenario: EOS 后快速重连，SPEAKING 期间 ASR 在听

- **WHEN** 用户说完一段（ASR 判定 EOS）、引擎进入 PROCESSING/SPEAKING、AI 开始播放回复
- **THEN** 上一轮的 ASR 连接 SHALL 在 ~数百毫秒内完成关闭并重连，使 AI 说话期间存在一个活的 ASR 连接接收用户音频；MUST NOT 出现长达数秒、覆盖 AI 整轮 SPEAKING 的 ASR 失聪窗口

#### Scenario: AI 说话期间用户插话被检测到

- **WHEN** AI 正在 SPEAKING、用户开口插话
- **THEN** 活的 ASR 连接 SHALL 产出 partial，`_partial_monitor` SHALL 据此判定打断并取消 `current_speaking_task`；MUST NOT 因 ASR 连接处于关闭/重连阻塞态而收不到任何 partial
