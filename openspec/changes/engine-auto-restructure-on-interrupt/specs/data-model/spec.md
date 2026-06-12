## ADDED Requirements

### Requirement: campaign.auto_restructure_on_interrupt 被打断自动重组开关

`campaign` 表 SHALL 持有 `auto_restructure_on_interrupt` 列（`Boolean`，NOT NULL，`server_default=sa.false()` / Python 默认 `False`）。该列为布尔开关：ON 时引擎在门控 decider 缺省（无显式 routing rule 命中）、本轮存在 barge-in 残留（`session.interrupt_remaining_text` 非空）且配置了 `kind=restructure` role_config 时，把缺省出口由 continue 改判为 `restructure(source=interrupt_remaining)`（语义见 ai-pipeline § 被打断自动重组开关）。默认 `False` → 行为与引入前一致；该列与既有 `routing_rules` / `max_continuous_restructure` / `interruption_*` 列同属 campaign 的打断与重组配置面。

#### Scenario: 新列加性迁移回填默认值

- **WHEN** isales-common Alembic 迁移在已有数据的 `campaign` 表上新增 `auto_restructure_on_interrupt` 列（down_revision 接当前 head `f7a8b9c0d1e2`）
- **THEN** 迁移 MUST 以 `server_default=sa.false()` 回填所有存量行，列 NOT NULL 不产生 NULL 窗口
- **AND** 存量 campaign 默认关闭，被打断后的决策行为 MUST 与迁移前逐字节一致

#### Scenario: schema 暴露与 PATCH 写入

- **WHEN** 客户端通过 campaign API 读取或 PATCH `auto_restructure_on_interrupt`
- **THEN** `CampaignBase` / `CampaignRead` MUST 含该字段（`bool`，默认 `False`），`CampaignUpdate` MUST 以可选字段（`bool | None`）支持部分更新；isales-api MUST NOT 在字段白名单层（`CampaignNestedUpdate`）静默丢弃该字段
