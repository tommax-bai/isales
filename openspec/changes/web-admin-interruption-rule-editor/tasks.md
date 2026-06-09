# Tasks — web-admin-interruption-rule-editor

> 进度回写：完成 task 用 `- [x]` + 行尾 HTML 注释 `<!-- commit-sha 备注 -->`。仅 isales-web。
> 实装 2026-06-09：web `3fda155`（代码+测试）;部署 web `index-2N9a3n2p.js` 到 ECS。

## 1. web 类型 + 工厂

- [x] 1.1 `src/types/campaign.ts`：递归 `InterruptionRule` discriminated-union（6 叶子 + and/or/not），镜像后端 schema <!-- 3fda155 -->
- [x] 1.2 `Campaign` 加 `interruption_rules: InterruptionRule | null`；`CAMPAIGN_DEFAULTS` 加 `interruption_rules: null`（buildPayload 白名单自动含） <!-- 3fda155 -->
- [x] 1.3 `makeRule(type)` 工厂 + `defaultTreeFrom(whitelist,minDurationMs)`（复刻引擎 default_rule 公式，whitelist 空省 keyword） <!-- 3fda155 -->

## 2. 递归编辑器组件 InterruptionRuleEditor.vue

- [x] 2.1 新 `InterruptionRuleEditor.vue`：props modelValue + emit update；顶部类型选择器（且/或/非/关键词/长度/时长/正则/分隔符/无） <!-- 3fda155 -->
- [x] 2.2 类型切换 → `makeRule(newType)` 整体替换（design D2） <!-- 3fda155 -->
- [x] 2.3 and/or 子列表（嵌套自身 + 删除[至少留1] + 加子规则）、not 单子；**不可变更新**（新数组/新对象，design D3） <!-- 3fda155 -->
- [x] 2.4 叶子渲染：keyword（el-select tag + 包含/精确）/ length / duration / regex（≤128 提示）/ split_by_delimiter（tag）/ none <!-- 3fda155 -->
- [x] 2.5 缩进 + 左边框区隔嵌套 + `--isales-*` token + 只读中文 summary 行 <!-- 3fda155 -->

## 3. InterruptionTab.vue 集成

- [x] 3.1 legacy 字段下加「高级:可组合打断规则」区 <!-- 3fda155 -->
- [x] 3.2 null：「使用默认规则」+「基于默认规则开始编辑」→ defaultTreeFrom 灌入 <!-- 3fda155 -->
- [x] 3.3 已配:渲染 editor + 「恢复为默认」→ null <!-- 3fda155 -->
- [x] 3.4 绑 form.interruption_rules，随既有 buildPayload PATCH <!-- 3fda155 -->

## 4. 保存校验反馈

- [x] 4.1 `el-form-item :error="fieldErrors?.interruption_rules"`（复用 CampaignDetail fieldErrors，422 就地）；前端仅软提示硬限 <!-- 3fda155 -->

## 5. 测试

- [x] 5.1 `tests/interruptionRuleEditor.test.ts` 10 case：类型切换重建 / 子节点不可变（防串台）/ defaultTreeFrom 公式（含·不含 whitelist）/ 恢复 null / makeRule 形状 / null 态 UI / seed / restore <!-- 3fda155 -->
- [x] 5.2 `npm run typecheck` 通过 <!-- 3fda155 -->
- [x] 5.3 `npm test` 全绿（17 files / 66 tests） <!-- 3fda155 -->

## 6. 部署

- [x] 6.1 build → tar dist → ECS `/var/www/isales-web/`（备份 web-rule-editor-20260609-100936）+ nginx reload，SPA 200，entry `index-2N9a3n2p.js` <!-- 2026-06-09 -->
- [ ] 6.2 浏览器人工验：场景「打断保护」→ 高级区建树/嵌套/切类型/保存（默认 campaign 走「使用默认规则」态）；显式树保存成功 + 超深/超长 regex 验 422 就地提示 —— **待用户在浏览器点验**

## 7. 收尾

- [x] 7.1 `openspec validate web-admin-interruption-rule-editor --strict` 通过 <!-- 2026-06-09 -->
- [ ] 7.2 浏览器验(§6.2)后 → `/opsx:archive`（合并 web-admin-ui delta 到 specs/）
- [x] 7.3 更新 `deploy/cloud/STATE.md`（web 部署 entry） <!-- 2026-06-09 -->

