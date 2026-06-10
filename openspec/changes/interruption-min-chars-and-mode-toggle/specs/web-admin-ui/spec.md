## MODIFIED Requirements

### Requirement: 场景打断规则可组合编辑

场景（campaign）配置 SHALL 在「打断配置」卡片（原标题「打断保护」）下提供 barge-in 判定的**两段互斥模式切换**「高级设置 ∣ 非高级设置」。当前模式 SHALL 由后端 `campaign.interruption_rules` 是否为 NULL 派生：NULL = 非高级（basic），非 NULL = 高级（advanced）；两模式 MUST NOT 同时生效（同一时刻只渲染其一的编辑区）。切到高级 MUST 用当前非高级字段合成初始规则树灌入编辑器（令 `interruption_rules` 非 NULL）；切回非高级 MUST 把 `interruption_rules` 清回 NULL。

- **非高级设置** 模式 SHALL 暴露三个标量字段：打断白名单（写 `interruption_whitelist`）、最小打断时长（写 `interruption_min_duration_ms`）、**最小打断字数**（写 `interruption_min_chars`，整数 ≥ 1，默认 2）。此模式下 `interruption_rules` 保持 NULL，引擎走 legacy 标量列合成默认树。
- **高级设置** 模式 SHALL 展示可组合规则树编辑器，支持组合节点 `and` / `or` / `not` 与叶子节点 `keyword`（含 `match` = 子串/精确 + 词集）/ `length` / `duration` / `regex` / `split_by_delimiter` / `none`，并 SHALL 以递归方式支持任意嵌套，写入 `campaign.interruption_rules`。保存前规则树随 campaign 提交，由 isales-api 校验（结构合法性 + 深度/节点上限 + regex pattern 长度上限）；校验失败前端 MUST 就地提示。
- **最大连续打断** 与 **连续打断策略** SHALL 作为**与模式无关**的字段，渲染在模式切换器**下方**，两种模式下均常显可编辑。

规则树文案与默认值 MUST 用客户能理解的语言呈现（对齐 STYLE_GUIDE，不直接暴露引擎内部字段名 —— 组合用「且/或/非」、叶子用「关键词/长度/时长/正则/分隔符」表述）。

#### Scenario: 非高级模式配置三个标量字段

- **WHEN** 管理员在「非高级设置」模式编辑 打断白名单 / 最小打断时长 / 最小打断字数 并保存
- **THEN** 三字段 MUST 随 campaign PATCH 分别写入 `interruption_whitelist` / `interruption_min_duration_ms` / `interruption_min_chars`，`interruption_rules` MUST 保持 NULL

#### Scenario: 切到高级模式播种初始树

- **WHEN** 管理员从「非高级设置」切到「高级设置」
- **THEN** UI MUST 用当前白名单 + 最小打断时长 + 最小打断字数生成初始树 `AND( NOT keyword(exact, 白名单), length(≥最小打断字数), duration(≥最小时长) )`（白名单为空时省略 keyword 子节点，与引擎 `default_rule` 同公式）灌入编辑器，令 `interruption_rules` 非 NULL；此时尚未保存，管理员可继续增删改

#### Scenario: 切回非高级模式清空规则树

- **WHEN** 管理员从「高级设置」切回「非高级设置」
- **THEN** UI MUST 把 `interruption_rules` 清回 NULL（保存后引擎回到由 legacy 标量列合成默认树的语义），MUST NOT 残留半棵树；非高级三个标量字段重新可编辑

#### Scenario: 两模式互斥不并存

- **WHEN** 渲染打断配置卡
- **THEN** 模式切换器 MUST 反映 `interruption_rules == null` 的当前态，且 MUST NOT 同时展示非高级标量编辑区与高级规则树编辑区

#### Scenario: 管理员组合配置打断规则并保存

- **WHEN** 管理员在「高级设置」模式用 and/or/not + 叶子节点搭出一棵打断规则树并保存
- **THEN** 前端 MUST 把规则树随 campaign 提交，校验通过后写入 `campaign.interruption_rules`；校验失败（422 `interruption_rule_invalid`）MUST 就地提示具体错误（非法 type / 超深 / regex 过长），MUST NOT 写入坏配置

#### Scenario: 切换节点类型重建为该类型默认形状

- **WHEN** 管理员把某个规则节点的类型从一种切到另一种（如 关键词 → 且）
- **THEN** 该节点 MUST 重建为新类型的合法默认形状（如「且」默认带一个子规则、「关键词」默认空词集 + 包含模式），MUST NOT 残留旧类型的字段产生非法形状

#### Scenario: 连续打断字段模式无关常显

- **WHEN** 打断配置卡处于任一模式（高级 / 非高级）
- **THEN** 最大连续打断 与 连续打断策略 字段 MUST 渲染在模式切换器下方并可编辑
