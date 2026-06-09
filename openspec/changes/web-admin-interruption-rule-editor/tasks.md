# Tasks — web-admin-interruption-rule-editor

> 进度回写：完成 task 用 `- [x]` + 行尾 HTML 注释 `<!-- commit-sha 备注 -->`。仅 isales-web。

## 1. web 类型 + 工厂

- [ ] 1.1 `src/types/campaign.ts`：加递归 `InterruptionRule` discriminated-union（叶子 `KeywordRule{type,values,match}` / `LengthRule{type,value}` / `DurationRule{type,value_ms}` / `RegexRule{type,pattern}` / `SplitByDelimiterRule{type,delimiters}` / `NoneRule{type}` + 组合 `AndRule{type,rules[]}` / `OrRule{type,rules[]}` / `NotRule{type,rule}`），镜像后端 schema
- [ ] 1.2 `Campaign` 接口加 `interruption_rules: InterruptionRule | null`；`CAMPAIGN_DEFAULTS` 加 `interruption_rules: null`（→ buildPayload 白名单自动含）
- [ ] 1.3 `makeRule(type): InterruptionRule` 工厂：各 type 默认合法形状（and/or 默认带 1 子叶子、not 默认含 1 子叶子、keyword 空词集+contains 等）；`defaultTreeFrom(whitelist, minDurationMs): InterruptionRule` 复刻引擎 `default_rule` 公式（whitelist 空则省 keyword）

## 2. 递归编辑器组件 InterruptionRuleEditor.vue

- [ ] 2.1 新 `src/views/Campaigns/Tabs/InterruptionRuleEditor.vue`：props `modelValue: InterruptionRule` + emit `update:modelValue`；顶部「类型」选择器（且/或/非/关键词/长度/时长/正则/分隔符/无）
- [ ] 2.2 类型切换 → 整体替换为 `makeRule(newType)`（design D2，不留旧字段）
- [ ] 2.3 组合节点渲染：`and/or` 子规则列表（每个子=嵌套 `<InterruptionRuleEditor>` + 删除 + 「加子规则」按钮，至少留 1 个）；`not` 单子嵌套；**不可变更新**子节点（map 出新数组 / 新对象，design D3，禁直接 mutate props）
- [ ] 2.4 叶子渲染：keyword（词集 tag-input + 包含/精确切换）/ length（字数 number）/ duration（ms number）/ regex（文本 + 「≤128 字」软提示）/ split_by_delimiter（分隔符 tag-input）/ none（说明「禁用打断」）
- [ ] 2.5 视觉:每层缩进 + 卡片/左边框区隔嵌套；用 `--isales-*` token（[[feedback_webui_style_guide]]）；可选只读 summary 行（design Q3）

## 3. InterruptionTab.vue 集成

- [ ] 3.1 在 legacy「打断保护」字段下加「高级:可组合打断规则」区
- [ ] 3.2 `interruption_rules==null`：显示「使用默认规则（由白名单+最小时长自动合成）」+「基于默认规则开始编辑」按钮 → `defaultTreeFrom(form.interruption_whitelist, form.interruption_min_duration_ms)` 灌入 + 切到编辑态
- [ ] 3.3 已配:渲染 `<InterruptionRuleEditor v-model="form.interruption_rules">` + 「恢复为默认」按钮 → 置 `interruption_rules=null`
- [ ] 3.4 v-model 绑 `form.interruption_rules`（CampaignDetail form），保存随既有 buildPayload PATCH

## 4. 保存校验反馈

- [ ] 4.1 保存 422 `interruption_rule_invalid:<reason>` → 在 tab 顶就地红字提示（复用 CampaignDetail fieldErrors 机制）；前端仅软提示硬限,不重复实现（design D5）

## 5. 测试

- [ ] 5.1 `tests/`：editor 单测 —— ① 类型切换重建为默认形状（keyword→and 后有 rules[]）；② 改一个子节点不影响兄弟（不可变更新,防引用串台）；③ `defaultTreeFrom` 公式正确（含/不含 whitelist 两情形）；④ 恢复默认 → null
- [ ] 5.2 `npm run typecheck` 通过（递归类型 + 组件 props）
- [ ] 5.3 `npm test`（vitest）全绿

## 6. 部署

- [ ] 6.1 `npm run build` → rsync dist → ECS `/var/www/isales-web/`（备份）+ nginx reload（SPA 200）；同既有 web 部署 pattern（[[feedback_ecs_deploy_scp]]）
- [ ] 6.2 浏览器验：场景「打断保护」→ 高级区可建树/嵌套/切类型/保存（默认 campaign 走「使用默认规则」态）；配一棵显式树保存成功 + 故意配超深 regex 验 422 就地提示

## 7. 收尾

- [ ] 7.1 `openspec validate web-admin-interruption-rule-editor --strict` 通过
- [ ] 7.2 全 task + 浏览器验证后 → `/opsx:archive`（合并 web-admin-ui delta 到 specs/）
- [ ] 7.3 更新 `deploy/cloud/STATE.md`（web 部署 entry）
