## ADDED Requirements

### Requirement: 场景打断规则可组合编辑

场景（campaign）配置 SHALL 提供「打断规则」编辑入口，让管理员可组合配置 barge-in 判定规则树（写入 `campaign.interruption_rules`）。编辑器 SHALL 支持组合节点 `and` / `or` / `not` 与叶子节点 `keyword`（含 `match` = 子串/精确 + 词集）/ `length` / `duration` / `regex` / `split_by_delimiter` / `none`。保存前 SHALL 经 isales-api 的规则树校验 endpoint 校验（结构合法性 + 深度/节点上限 + regex pattern 长度上限）。

未配置时 UI SHALL 展示「使用默认规则」状态（后端 `interruption_rules` 为 NULL，引擎走 legacy 列合成的等价默认树），并允许管理员一键基于默认树开始编辑。规则树文案与默认值 MUST 用客户能理解的语言呈现（对齐 STYLE_GUIDE，不直接暴露引擎内部字段名）。

> 实现分阶段：本 change 先落 engine 规则树 + 默认树等价 + api 校验；web 编辑面可在 engine 上线后单独 task section 推进。spec 在此定下编辑契约。

#### Scenario: 管理员组合配置打断规则并保存

- **WHEN** 管理员在场景配置中用 and/or/not + 叶子节点搭出一棵打断规则树并保存
- **THEN** 前端 MUST 调 isales-api 校验 endpoint，校验通过后写入 `campaign.interruption_rules`；校验失败 MUST 就地提示具体错误（非法 type / 超深 / regex 过长），MUST NOT 写入坏配置

#### Scenario: 未配置时展示默认规则

- **WHEN** 场景的 `interruption_rules` 为 NULL
- **THEN** UI MUST 显示「使用默认规则」（不报空错），并提供一键基于默认树开始编辑的入口
