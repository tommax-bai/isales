## MODIFIED Requirements

### Requirement: per-campaign 外呼策略配置

外呼策略配置 SHALL 绑定到具体 campaign 并持久化到后端，不再是全局配置。campaign 详情 view SHALL 承载以下 per-campaign 配置：**3-tier 串行 LLM（main / referee / extractor）**、可拨时段、选用音色、**filler_enabled toggle 与 filler_delay_ms 触发延迟**。配置 SHALL 通过 admin API 持久化（`role_config` / `prompt_version` 按 campaign 写入；`campaign.time_windows` / `campaign.voice_id` / `campaign.filler_enabled` / `campaign.filler_delay_ms` / `campaign.filler_phrases` 通过 campaign PATCH 写入），MUST NOT 仅存于浏览器 localStorage。

#### Scenario: 配置入口先选定 campaign

- **WHEN** 用户要编辑 AI 外呼策略
- **THEN** SHALL 先进入某个 campaign 的详情 view，配置区操作的对象 SHALL 明确归属该 campaign

#### Scenario: 三 LLM prompt 编辑（per-campaign）

- **WHEN** 用户在 campaign 详情的 AI 外呼配置区编辑 main / referee / extractor 之一
- **THEN** 表单 SHALL 提供 name / model provider / model name / temperature(0–2) / topP(0–1) / prompt 文本 / enable 开关；保存后 SHALL 通过 admin API 写入归属该 `campaign_id` 的 `role_config` + `prompt_version`，kind / scope_type ∈ `{main, referee, extractor}`

#### Scenario: filler_enabled toggle

- **WHEN** 用户在 campaign 详情 view 切换 filler 启用开关
- **THEN** UI SHALL 调 campaign PATCH API 写入 `campaign.filler_enabled` 字段（bool, default false）；切到 false 时同 page 隐藏垫词输入区
- **AND** UI SHALL 在 filler 区上方显示提示"streaming 主链路首音频 ~500ms，filler 仅在用慢模型时建议启用"

#### Scenario: filler_delay_ms 触发延迟

- **WHEN** 用户在 campaign 详情 view 开启 filler 后编辑触发延迟
- **THEN** UI SHALL 展示 `filler_delay_ms` 数值输入（仅 `filler_enabled=true` 时可见），调 campaign PATCH API 写入 `campaign.filler_delay_ms`（int，可空，留空表示 engine 默认 600ms）

#### Scenario: 垫词输入（分号分隔，随 campaign PATCH）

- **WHEN** 用户在 campaign 详情 view 编辑垫词
- **THEN** UI SHALL 展示单行分号分隔输入（参照打断白名单），失焦时解析为 `list[str]`，随页面底部「保存」一起通过 campaign PATCH 写入 `campaign.filler_phrases`（无独立即时端点、无「组」概念）

#### Scenario: 时段与音色

- **WHEN** 用户在 campaign 详情编辑可拨时段或选用音色
- **THEN** 可拨时段 SHALL 写入该 `campaign.time_windows`；音色 SHALL 从全局音色库（`voice_model`）中选择并写入 `campaign.voice_id`

#### Scenario: 配置持久化替代 localStorage

- **WHEN** 用户保存某 campaign 的外呼策略后刷新页面
- **THEN** 配置 SHALL 从后端重新加载并保持一致
