## ADDED Requirements

### Requirement: 被打断自动重组开关 UI 配置

场景（campaign）配置 SHALL 在「打断配置」卡片下提供 `auto_restructure_on_interrupt` 的布尔开关（`el-switch`），作为**与高级 / 非高级模式无关**的字段，渲染在打断模式切换器**下方**（与 最大连续打断 / 连续打断策略 同区），两种模式下均常显可编辑、MUST NOT 随模式切换隐藏或重置。

开关文案 MUST 用客户能理解的语言说明其作用与代价（对齐 STYLE_GUIDE，不暴露引擎内部字段名 / `restructure` / `referee` 等术语）：开启后"当客户用没有营养的话（垫词、语气词、随口附和）打断、且没有触发任何挂断 / 转人工 / 拒识等规则时，AI 会自动把刚被打断那句话顺一顺、接着说完"；并 MUST 提示代价"如果客户是真的提问或反对而打断，仍由门控规则正常接管去回应——所以建议把挂断 / 转人工 / 拒识等规则配齐再开此开关"。

该开关随 campaign PATCH 持久化（写 `auto_restructure_on_interrupt`），无需额外端点；回读 MUST 反映保存值。

#### Scenario: 开关随 campaign PATCH 持久化

- **WHEN** 管理员在「打断配置」卡切换"被打断自动续说"开关并保存
- **THEN** 前端 MUST 把 `auto_restructure_on_interrupt`（bool）随 campaign PATCH 写入，保存后回读 MUST 反映该值

#### Scenario: 开关模式无关常显

- **WHEN** 「打断配置」卡处于任一模式（高级 / 非高级）
- **THEN** 该开关 MUST 渲染在模式切换器下方并可编辑，MUST NOT 随模式切换隐藏、重置或与高级规则树编辑区互斥

#### Scenario: 开关文案呈现作用与代价

- **WHEN** 渲染该开关
- **THEN** 旁注 MUST 同时说明"开启后没营养的打断会自动续说"与"真问题 / 真异议打断仍由门控规则正常回应"，MUST NOT 直接暴露 `restructure` / `referee` / `interrupt_remaining` 等引擎内部标识符
