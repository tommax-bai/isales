## Context

后端契约已定且上线（`engine-interruption-rule-tree`）：`campaign.interruption_rules` 是一棵 discriminated-union 规则树（按 `type` 判别），NULL = 引擎从 legacy `interruption_whitelist`+`interruption_min_duration_ms` 合成等价默认树。api 在 campaign create/update 校验该字段（结构/类型/regex≤128 由 common Pydantic schema；深度≤8/节点≤64 由 `validate_interruption_rule` → 422 `interruption_rule_invalid`）。web 缺的只是编辑面。

现状 web：`InterruptionTab.vue` 编辑 legacy 字段；`CampaignDetail.vue::buildPayload` 发 `Object.keys(CAMPAIGN_DEFAULTS)` 白名单 → 只要把 `interruption_rules` 进 `CAMPAIGN_DEFAULTS` 即随既有 PATCH 提交；`RoutingAction` 是现成的 TS discriminated-union 范例。

## Goals / Non-Goals

**Goals:**
- 可视化增删改一棵可组合规则树（且/或/非 + 6 叶子），保存随既有 campaign PATCH。
- `interruption_rules==null` 时清楚展示「用默认规则」+ 一键基于默认树开始编辑；可恢复为默认（清回 null）。
- 镜像后端 schema 的 TS 类型；前端只做软提示,硬限交 api（避免前后端校验漂移）。
- 文案中文化、对齐 STYLE_GUIDE，不暴露引擎英文字段名。

**Non-Goals:**
- 不动 legacy「打断保护」字段（向后兼容）。
- 不在前端重复实现深度/节点/regex 硬限（交 api 422,前端仅软提示)。
- 不做规则树的"实时模拟某句话是否打断"预览（可作后续）。
- 不动 engine/common/api（后端已就绪）。

## Decisions

### D1. 递归自引用组件 `InterruptionRuleEditor.vue`
单个组件渲染**一个节点**，组合节点（and/or/not）对子节点**递归渲染自身**（Vue SFC 通过 `name` 选项自引用，或显式 import 自身）。props: `modelValue: InterruptionRule`；emit `update:modelValue`。`and/or` 渲染子节点列表（每个子节点一个嵌套 editor + 删除按钮 + 「加子规则」）；`not` 渲染单个嵌套 editor；叶子渲染对应输入控件。

**Why**：规则树是同构递归结构，自引用组件是最自然的表达；每层只管自己 + 把子树委托给下一层。

### D2. 节点类型切换 = 重建该节点为该类型的默认 shape
顶部一个「类型」选择器（且/或/非/关键词/长度/时长/正则/分隔符/无）。切换类型时**替换整个节点对象**为该类型的默认实例（如切到 `keyword` → `{type:'keyword',values:[],match:'contains'}`；切到 `and` → `{type:'and',rules:[<一个默认叶子>]}`），而非保留旧字段。用工厂函数 `makeRule(type)` 产默认节点。

**Why**：discriminated-union 各 type 字段不同，混留旧字段会产生非法形状；整体替换最干净。**Trade-off**：切类型丢当前子配置 —— 可接受（切类型本就是换语义）。

### D3. v-model 深拷贝 + 不可变更新，防引用串台
递归 v-model 最大坑是子节点共享对象引用导致"改一个串改多个"。**决定**：每次子节点变更走**不可变更新**——`and/or` 的子列表更新时 `rules = rules.map((r,i)=> i===idx ? newChild : r)`（新数组）；初始 seed / `makeRule` 用结构化深拷贝（`structuredClone` 或手写 clone）。组件内不直接 mutate props.modelValue,一律 emit 新对象。

**Why**：Vue 响应式 + 递归 + 共享引用是经典 bug 源；不可变更新 + 深拷贝根除。

### D4. 默认树 seed 与「恢复默认」
- `interruption_rules==null`：tab 显示「使用默认规则（由白名单+最小时长自动合成）」说明 + 「基于默认规则开始编辑」按钮。点击 → 用**当前表单的** `interruption_whitelist` + `interruption_min_duration_ms` 生成 `AND( NOT keyword(exact, whitelist), length(2), duration(min_duration_ms) )` 灌入编辑器（whitelist 为空则省略 keyword 子节点，对齐引擎 `default_rule`）。
- 已配（非 null）：渲染编辑器 + 「恢复为默认」按钮 → 置 `interruption_rules=null`（回到合成默认树语义）。

**Why**：让管理员不必从零搭树；「恢复默认」给安全退路。seed 公式与引擎 `default_rule` 一致,避免"开始编辑"就改变了行为。

### D5. 保存与校验反馈
保存复用 `CampaignDetail.buildPayload`（`interruption_rules` 进 `CAMPAIGN_DEFAULTS` 即随 PATCH）。前端只做**软提示**（regex 框旁提示「≤128 字」、树过深时提示「层级较深」），**硬校验交 api**：保存 422 `interruption_rule_invalid:<reason>` → 在 tab 顶就地红字提示。

**Why**：前端重复实现硬限会与后端漂移（design 原则：单一真相源在 api/common schema）。

## Risks / Trade-offs

- **[递归组件 v-model 引用串台]** → D3 不可变更新 + 深拷贝；单测覆盖"改一个子节点不影响兄弟"。
- **[Element Plus 嵌套表单视觉混乱]** → 每层用缩进 + 左边框/卡片区隔；深层加视觉层级（STYLE_GUIDE token）。
- **[空 and/or（rules:[]）非法]** → `makeRule('and'/'or')` 默认带一个叶子；删到最后一个子节点时禁删或回退；api 也会 422 兜底。
- **[切类型误删配置]** → 接受（D2）；可加二次确认（apply 时定，倾向不加,保持轻快）。

## Migration Plan

web-only：实现 → `npm run typecheck` + `vitest` 绿 → build → rsync dist 到 ECS `/var/www/isales-web/` + nginx reload（同上次 web 部署）。无 DB / 后端改动。**Rollback**：rsync 回 backup dir + nginx reload。

## Open Questions

- **Q1**：编辑器放 `src/components/` 还是 `src/views/Campaigns/Tabs/`？→ 倾向 `Tabs/` 旁（仅此处用）；apply 时定。
- **Q2**：切类型是否二次确认？→ 倾向不加（轻快）；apply 时定。
- **Q3**：是否加"规则树文字预览"（把树渲染成一句中文如「且(非 关键词…, 长度≥2, 时长≥200ms)」）辅助理解？→ 倾向加一个只读 summary 行,低成本高可读；apply 时定。
