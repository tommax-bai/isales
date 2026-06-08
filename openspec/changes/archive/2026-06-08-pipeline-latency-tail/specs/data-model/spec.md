## ADDED Requirements

### Requirement: campaign.asr_eos_silence_ms 端点静默阈值

`campaign` 表 SHALL 含 `asr_eos_silence_ms`（INT，nullable）字段，表示 ASR 判定用户说完（EOS）所需的稳定静默时长（毫秒）。NULL MUST 走系统默认（400ms）。engine `load_runtime_config` SHALL 读出该值透传给 ASR provider 构造，覆盖写死的端点阈值。

取值是 latency 与"误把停顿当说完打断用户"的权衡：越小开口越快、越易误打断犹豫的客户；campaign MUST 能按话术 / 客群停顿习惯独立调整。

#### Scenario: NULL 走默认

- **WHEN** campaign `asr_eos_silence_ms IS NULL`
- **THEN** engine SHALL 用系统默认 400ms 作为 ASR 端点静默阈值

#### Scenario: campaign 覆盖

- **WHEN** campaign `asr_eos_silence_ms = 250`
- **THEN** engine SHALL 用 250ms；该 campaign 的通话 EOS 判定更激进

#### Scenario: 透传到 ASR provider

- **WHEN** `load_runtime_config` 组装 RuntimeConfig
- **THEN** `asr_eos_silence_ms`（或默认）MUST 透传到 ASR provider 的端点检测参数，替换写死常量
