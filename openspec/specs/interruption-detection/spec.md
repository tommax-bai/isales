## Purpose

定义 SPEAKING 状态下用户说话是否构成"打断"的判定逻辑。误判为打断会让 AI 反应过度（被「嗯嗯」中断），漏判则用户感觉被 AI 强行覆盖。本规范覆盖判定算法、不可撤销策略、连续打断保护、ASR Provider 接入边界。
## Requirements
### Requirement: 双条件打断判定

SPEAKING 状态下 engine SHALL 根据两个独立条件判定用户说话是否构成"打断"。**任一条件满足时 engine MUST 视为非打断**：白名单短语命中 OR 时长 < 阈值。

#### Scenario: 用户说出白名单短语

- **WHEN** SPEAKING 期间 ASR 中间结果文本完全等于 `campaign.interruption_whitelist` 中任一短语（如「嗯」「好的」）
- **THEN** 不视为打断，TTS 继续，用户输入将被丢弃

#### Scenario: 用户说话时长低于阈值

- **WHEN** SPEAKING 期间 ASR speech_start 至当前时刻的间隔小于 `campaign.interruption_min_duration_ms`（默认 800ms）
- **THEN** 不视为打断，TTS 继续

#### Scenario: 用户说话满足打断条件

- **WHEN** ASR 中间结果文本不在白名单中 **且** 持续时长已超过阈值
- **THEN** engine 立刻停止 TTS、状态转为 INTERRUPTED → PROCESSING，使用 ASR 终态结果作为本轮用户输入

### Requirement: 打断判定不可撤销

一旦判定为"打断"，engine SHALL 立即停止 TTS 并切换状态，**MUST NOT 回退**到 SPEAKING（即使后续 ASR 中间结果显示其实是嗯嗯）。代价是可能误打断（用户先嗯嗯再说"你接着说"会被截）；收益是实现简单、状态机清晰、延迟低。

#### Scenario: 已判定打断后再收到白名单匹配

- **WHEN** engine 已停止 TTS 进入 INTERRUPTED 后，ASR 推送的下一个中间结果命中白名单
- **THEN** 维持 INTERRUPTED 状态，不恢复 TTS

### Requirement: 连续打断保护

当连续 INTERRUPTED → PROCESSING → SPEAKING → INTERRUPTED 循环超过 `campaign.max_continuous_interruptions`（默认 3）时，engine SHALL 触发保护策略以避免无限循环。保护策略 MUST 由 `campaign.continuous_interruption_strategy` 配置决定。

#### Scenario: 触发 short_reply 策略（默认）

- **WHEN** 连续打断次数达到上限 **且** `campaign.continuous_interruption_strategy = "short_reply"`
- **THEN** 角色 LLM prompt 临时追加「请用一句话回应」，避免长 TTS 再被打断

#### Scenario: 触发 listen_only 策略

- **WHEN** 连续打断次数达到上限 **且** `campaign.continuous_interruption_strategy = "listen_only"`
- **THEN** AI 主动说一句「您请说」，进入纯听模式，等用户 speech_end 后再回应

#### Scenario: 完整轮次后计数器重置

- **WHEN** 用户完成一轮完整对话（无打断的 SPEAKING）
- **THEN** 连续打断计数器清零

### Requirement: ASR Provider 抽象与 VAD 来源

打断判定 SHALL 基于流式 ASR 的中间结果与 VAD 事件；engine MUST NOT 依赖独立的 VAD 模型。所有接入的 ASR Provider MUST 实现 `isales-common.providers.asr` 接口。

#### Scenario: ASR Provider 必须支持的能力

- **WHEN** 接入新的 ASR Provider
- **THEN** 该 Provider 必须实现 `isales-common.providers.asr` 接口，提供：流式中间结果（partial result）持续推送、speech_start / speech_end VAD 事件（带时间戳）

#### Scenario: v1 默认 ASR Provider

- **WHEN** v1 部署 / 未配置自定义 ASR Provider
- **THEN** 使用火山引擎（豆包）实时语音识别作为默认实现

### Requirement: 与 FILLER / WRAPPING_UP 状态的交互

打断判定逻辑 MUST 在 FILLER 和 WRAPPING_UP 状态下保持一致；engine SHALL 仅调整后续 PROCESSING 路径。

#### Scenario: FILLER 期间用户说话被判定为打断

- **WHEN** FILLER 状态正在播放垫词，ASR 中间结果触发"打断"判定
- **THEN** engine 停止垫词、丢弃当前 PROCESSING 中的 AI 管线、把用户输入作为新一轮处理

#### Scenario: WRAPPING_UP 期间被打断

- **WHEN** WRAPPING_UP 状态触发"打断"判定
- **THEN** 判定逻辑不变；进入 PROCESSING 后走简化管线（仅 main LLM 流式，跳过 referee）

## Configuration

`campaign` 表新增字段：

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `interruption_whitelist` | JSONB array | `["嗯","嗯嗯","好","好的","哦","哦哦","对","是的"]` | 白名单短语，整段完全匹配 |
| `interruption_min_duration_ms` | int | 800 | 时长阈值，低于此值视为非打断 |
| `max_continuous_interruptions` | int | 3 | 触发保护策略前允许的连续打断次数 |
| `continuous_interruption_strategy` | enum | `short_reply` | `short_reply` / `listen_only` |

> 配置粒度：Campaign 级。不做全局默认覆盖、不做 Role 级独立配置。
