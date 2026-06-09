## Why

`engine-interruption-rule-tree`（已 archive）把 barge-in 决策升级成可组合规则树并落 `campaign.interruption_rules` JSONB + api 校验 + spec 契约（`web-admin-ui` § "场景打断规则可组合编辑"），但 web 编辑面被标为 phased follow-on（§10.1-2）未做。结果:管理员在场景「打断保护」tab 只能配 legacy 白名单 + 最小时长（引擎据此合成默认树），**无法**配置/查看真正的可组合规则树（and/or/not + 正则/子串关键词/长度/时长/分隔符）。本 change 补上这个可视化编辑器,兑现已存在的 spec 契约。

## What Changes

- **web 类型**：`types/campaign.ts` 加递归 `InterruptionRule` discriminated-union（叶子 `keyword`[values+match contains/exact]/`length`/`duration`/`regex`/`split_by_delimiter`/`none` + 组合 `and`/`or`/`not`，镜像后端 schema）；`Campaign` 加 `interruption_rules: InterruptionRule | null`；`CAMPAIGN_DEFAULTS` 加 `interruption_rules: null`（→ 经 `buildPayload` 既有白名单机制随 PATCH 自动提交）。
- **新组件** `InterruptionRuleEditor.vue`：递归树编辑器。组合节点（且/或）可增删子规则、非取单子规则；叶子按类型渲染输入（关键词:词集 tag-input + 包含/精确切换；长度:字数；时长:ms；正则:文本 + ≤128 长度提示；分隔符:tag-input；无:禁用）。中文 affordance（且/或/非、关键词/长度/时长/正则/分隔符），不暴露引擎英文字段名。
- **`InterruptionTab.vue` 集成**：在 legacy 字段下新增「高级:可组合打断规则」区。`interruption_rules==null` → 展示「使用默认规则（白名单+最小时长 自动合成）」+「基于默认规则开始编辑」按钮（用当前 whitelist/min_duration 生成 `AND(NOT keyword(exact,whitelist), length≥2, duration)` 初始树灌入编辑器）；已配 → 渲染树 + 「恢复为默认（清空）」按钮（置回 null）。
- **校验反馈**：保存失败 422 `interruption_rule_invalid:...` 就地提示（结构/类型/regex 长度/深度节点超限由 api + common schema 把关，前端不重复实现硬限,只给软提示）。

## Capabilities

### New Capabilities
无。

### Modified Capabilities

- `web-admin-ui`: 细化已存在的 "场景打断规则可组合编辑" Requirement —— 补「基于默认规则一键开始编辑」与「恢复为默认（清空回 NULL）」两个 affordance 的 Scenario（行为细化,不改契约方向）。

## Impact

- **仅 isales-web**：`src/types/campaign.ts`、`src/views/Campaigns/Tabs/InterruptionTab.vue`、新 `src/components/InterruptionRuleEditor.vue`（或 Campaigns/Tabs 下），可能 `tests/campaignTabs.test.ts`。
- **不动**：engine / common / api / scheduler / worker（后端 + api 校验已就绪）；legacy「打断保护」字段（whitelist/min_duration/max_continuous/strategy）保留不变（引擎 NULL 时仍据此合成默认树）。
- **spec**：`web-admin-ui`（MODIFIED 细化,无新行为方向）。
- **部署**：web build + rsync dist → ECS `/var/www/isales-web/` + nginx reload（同既有 web 部署 pattern）。
