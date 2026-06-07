## MODIFIED Requirements

### Requirement: 与 FILLER / WRAPPING_UP 状态的交互

打断判定逻辑 MUST 在 FILLER 和 WRAPPING_UP 状态下保持一致；engine SHALL 仅调整后续 PROCESSING 路径。

#### Scenario: FILLER 期间用户说话被判定为打断

- **WHEN** FILLER 状态正在播放垫词，ASR 中间结果触发"打断"判定
- **THEN** engine 停止垫词、丢弃当前 PROCESSING 中的 AI 管线、把用户输入作为新一轮处理

#### Scenario: WRAPPING_UP 期间被打断

- **WHEN** WRAPPING_UP 状态触发"打断"判定
- **THEN** 判定逻辑不变；进入 PROCESSING 后走简化管线（仅 main LLM 流式，跳过 referee）
