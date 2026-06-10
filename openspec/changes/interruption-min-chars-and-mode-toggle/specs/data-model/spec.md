## ADDED Requirements

### Requirement: campaign.interruption_min_chars 字数门控阈值

`campaign` 表 SHALL 持有 `interruption_min_chars` 列（`Integer`，NOT NULL，`server_default="2"` / Python 默认 `2`，schema 约束 `ge=1`）。该列表示 barge-in **缺省合成默认树**中 `length` 叶子的字数阈值——ASR partial strip 后 rune 数 ≥ 该值才可能构成打断。它与既有 `interruption_min_duration_ms`（时长阈值）对称，把原本硬编码在引擎 `default_rule(min_text_length=2)` 的字数门控提升为 Campaign 级可配字段。

该列 SHALL 仅在 `interruption_rules` 为 NULL（非高级模式）时被引擎读取用于合成默认树；campaign 配置了显式 `interruption_rules`（高级模式）时该列不参与判定。约束 `ge=1` 因 `length(value=0)` 会匹配空串（每个静默 partial 都过），非合理门控。默认 `2` 复刻历史硬编码值。

#### Scenario: 新列加性迁移回填默认值

- **WHEN** isales-common Alembic 迁移在已有数据的 `campaign` 表上新增 `interruption_min_chars` 列（down_revision 接当前 head `e6f7a8b9c0d1`）
- **THEN** 迁移 MUST 以 `server_default="2"` 回填所有存量行，列 NOT NULL 不产生 NULL 窗口
- **AND** 存量 null-rule campaign 的打断判定行为 MUST 与迁移前（硬编码字数≥2）逐字节一致

#### Scenario: 仅 null-rule campaign 读取该列

- **WHEN** campaign 的 `interruption_rules` 为 NULL
- **THEN** 引擎合成默认树时 `length` 叶子 `value` MUST 取 `campaign.interruption_min_chars`
- **WHEN** campaign 的 `interruption_rules` 为非 NULL 显式规则树
- **THEN** 引擎 MUST 忽略 `interruption_min_chars`，用显式树自身的 `length` 叶子（若有）

#### Scenario: schema 暴露与 PATCH 写入

- **WHEN** 客户端通过 campaign API 读取或 PATCH `interruption_min_chars`
- **THEN** `CampaignBase` / `CampaignRead` MUST 含该字段（`int`，`ge=1`），`CampaignUpdate` MUST 以可选字段（`int | None`）支持部分更新；isales-api MUST NOT 在字段白名单层静默丢弃该字段
