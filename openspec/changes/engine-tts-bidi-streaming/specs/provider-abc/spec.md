## MODIFIED Requirements

### Requirement: TTS Provider 异步流式合成接口

TTSProvider SHALL 暴露两类合成接口，按调用形态选用：

1. **一次性流式合成** `synthesize_stream(text, voice_id)`：输入单段文本与音色，输出 PCM 音频字节流（首包尽快返回以降低端到端延迟）。用于**单片段**场景（开场白、垫词、默认回复兜底、listen_only 引导语、isales-api 试听 preview）。
2. **会话式双向流式合成**（新增）：开启一个跨**多句**的合成 session，文本增量持续喂入同一 session，输出一条**连续** PCM 字节流，可中途关闭。用于一轮对话内 main 流式回复 / restructure 流式回复等多句连续合成 —— 使 vendor 跨句统一规划韵律，消除逐句独立冷请求造成的跨句音色 / 语气跳变。

会话式接口 SHALL 至少支持：开启 session（绑定 `voice_id`）、多次喂入文本片段、异步迭代取回连续 PCM、告知文本结束（正常收尾）、以及中途关闭（barge-in / teardown 立即释放 vendor 连接）。该接口属 provider-abc § "ABC 接口稳定性 / 新增可选参数" 的**新增可选能力**：一次性 `synthesize_stream` 签名与语义 MUST 保持不变，存量调用方零改动。

实现 MAY 以单向协议实装一次性接口、以双向流式协议实装会话式接口（如 Volcengine 豆包 V3：单向 SSE vs 双向 WS bidirection）。会话式接口的底层 vendor 资源（`resource_id`）与音色（speaker）若存在严格绑定约束（某些音色只支持单向、不支持双向），实现 SHALL 按音色家族选择正确的 vendor 资源；当配置的音色在会话式协议下不产音频（声学层不跑）时，实现 MUST 抛错 fail-loud，MUST NOT 静默回落到一次性接口掩盖配置错误。

#### Scenario: 一次性流式输出首包

- **WHEN** 调用 `synthesize_stream(text, voice_id)`
- **THEN** 接口 MUST 以 `AsyncIterator[bytes]` 返回 PCM chunks；首包 SHALL 在 500ms 内开始返回（依赖供应商能力，ABC 不强制超时但实现应自测）

#### Scenario: 会话式多句连续合成

- **WHEN** 调用方开启一个合成 session、依次喂入同一轮的多个句子、再告知文本结束
- **THEN** 接口 MUST 在**同一 vendor session 内**合成全部句子并以连续 PCM 流返回；vendor SHALL 跨句共享韵律上下文（句间不重置音高基线 / 句尾降调），使输出听感为一条连续嗓子而非逐句拼接
- **AND** 首句 PCM SHALL 尽快返回（不等全部句子喂完）

#### Scenario: 会话式中途关闭释放连接

- **WHEN** 调用方在 session 未正常收尾时主动关闭（如 barge-in 打断 / 通话 teardown）
- **THEN** 接口 MUST 立即关闭底层 vendor 连接并停止产音；MUST NOT 泄漏 vendor 会话 / 连接

#### Scenario: 音色由 voice_id 选择

- **WHEN** 调用合成（一次性或会话式）
- **THEN** 调用方 SHALL 传入 `campaign.voice_id`——一个不透明的 vendor speaker 标识字符串（如 `zh_female_xiaohe_uranus_bigtts`），原样透传给 TTS provider；该字符串不在本系统编目（`voice_model` 表已随 `admin-prune-vestigial-features` 删除），ABC 不关心 voice_id 的内部映射；`voice_id` 为空时实现 MAY 回落到 provider 默认音色

#### Scenario: 会话式音色与 vendor 资源不兼容时 fail-loud

- **WHEN** 配置的 `voice_id` 在会话式协议下不被底层 vendor 资源支持（如该音色仅支持一次性协议，会话式握手通过但声学层不产音频）
- **THEN** 实现 MUST 抛出 provider 错误（统一错误模型），MUST NOT 静默回落到一次性接口；该不兼容属配置错误，SHALL 在部署 / 配置期暴露
