## MODIFIED Requirements

### Requirement: 场景打断规则可组合编辑

场景（campaign）配置 SHALL 提供「打断规则」编辑入口，让管理员可组合配置 barge-in 判定规则树（写入 `campaign.interruption_rules`）。编辑器 SHALL 支持组合节点 `and` / `or` / `not` 与叶子节点 `keyword`（含 `match` = 子串/精确 + 词集）/ `length` / `duration` / `regex` / `split_by_delimiter` / `none`，并 SHALL 以递归方式支持任意嵌套。保存前规则树随 campaign 提交，由 isales-api 校验（结构合法性 + 深度/节点上限 + regex pattern 长度上限）；校验失败前端 MUST 就地提示。

未配置时 UI SHALL 展示「使用默认规则」状态（后端 `interruption_rules` 为 NULL，引擎走 legacy 列合成的等价默认树），并允许管理员**一键基于默认规则开始编辑**（用当前 `interruption_whitelist` + `interruption_min_duration_ms` 生成与引擎默认树同公式的初始树）。已配置时 SHALL 提供「恢复为默认」入口（清空回 NULL）。规则树文案与默认值 MUST 用客户能理解的语言呈现（对齐 STYLE_GUIDE，不直接暴露引擎内部字段名 —— 组合用「且/或/非」、叶子用「关键词/长度/时长/正则/分隔符」表述）。

#### Scenario: 管理员组合配置打断规则并保存

- **WHEN** 管理员在场景配置中用 and/or/not + 叶子节点搭出一棵打断规则树并保存
- **THEN** 前端 MUST 把规则树随 campaign 提交，校验通过后写入 `campaign.interruption_rules`；校验失败（422 `interruption_rule_invalid`）MUST 就地提示具体错误（非法 type / 超深 / regex 过长），MUST NOT 写入坏配置

#### Scenario: 未配置时展示默认规则

- **WHEN** 场景的 `interruption_rules` 为 NULL
- **THEN** UI MUST 显示「使用默认规则」（不报空错），并提供一键基于默认规则开始编辑的入口

#### Scenario: 一键基于默认规则开始编辑

- **WHEN** 管理员在 `interruption_rules` 为 NULL 时点击「基于默认规则开始编辑」
- **THEN** UI MUST 用当前表单的白名单 + 最小打断时长生成初始树 `AND( NOT keyword(exact, 白名单), length(≥2), duration(≥最小时长) )`（白名单为空时省略 keyword 子节点，与引擎 `default_rule` 同公式）并灌入编辑器，进入可编辑状态；此时尚未保存，管理员可继续增删改

#### Scenario: 恢复为默认

- **WHEN** 已配置 `interruption_rules` 的场景，管理员点击「恢复为默认」
- **THEN** UI MUST 把 `interruption_rules` 清回 NULL（保存后引擎回到由 legacy 列合成默认树的语义），MUST NOT 残留半棵树

#### Scenario: 切换节点类型重建为该类型默认形状

- **WHEN** 管理员把某个规则节点的类型从一种切到另一种（如 关键词 → 且）
- **THEN** 该节点 MUST 重建为新类型的合法默认形状（如「且」默认带一个子规则、「关键词」默认空词集 + 包含模式），MUST NOT 残留旧类型的字段产生非法形状
