# Tasks — web-admin-persona-enable-toggle

唯一受影响仓：`isales-web`。后端零改动（已核实引擎只认 `persona_fanout_cap`、api 已透传）。

## 1. PromptTierEditor.vue — 卡头开关接成功能开关

- [x] 1.1 `personaFanoutCap` 由只读 prop 改为双向 `defineModel<number>("personaFanoutCap")`（Vue 3.5 可用）；移除原 `personaFanoutCap?: number` prop。
- [x] 1.2 新增 `personaOn` computed：`get = (cap ?? 1) > 1`；`set(on) = cap = on ? max(2, cap ?? 2) : 1`。
- [x] 1.3 卡头 `el-switch` 改绑：collapsible 时 `v-model="personaOn"`，文案改「启用」/「关闭」（替代「展开」/「收起」）；`open` computed 改为派生自 `personaOn`（删除本地 `expanded` ref）。
- [x] 1.4 卡体顶部新增「人设并发上限」`el-input-number` `v-model="fanoutCap"` `:min="2" :max="3"`，仅 collapsible 卡渲染；加 hint 文案（投机并行总数含 main、门控选一其余取消计费）。
- [x] 1.5 cap-check（saveRow）改用 `fanoutCap.value` 取代 `props.personaFanoutCap`；提示文案由"请调高「门控路由 → 人设并发上限」"改为"请调高本卡「人设并发上限」"。
- [x] 1.6 更新 `collapsible` prop 注释（不再是"纯展示折叠、不影响运行语义"，改为"功能开关，绑 persona_fanout_cap"）。
<!-- isales-web 0bb40eb — PromptTierEditor.vue: defineModel + personaOn computed + 卡内并发上限控件 + cap-check 改 model 值 -->

## 2. CampaignDetail.vue — 双向绑定 + 文案

- [x] 2.1 persona 卡 `:persona-fanout-cap="form.persona_fanout_cap"` 改为 `v-model:persona-fanout-cap="form.persona_fanout_cap"`。
- [x] 2.2 更新 persona 卡 `description` + 上方 HTML 注释：并发上限/开关已在卡内，不再指向「门控路由」。
<!-- isales-web 0bb40eb — 仅 persona hunk(@167) 入本 commit；同文件 @242「打断保护→打断配置」是并发 session interruption-min-chars-and-mode-toggle 的改动，已显式排除、未 stage（hunk-level git apply --cached）。 -->

## 3. RoutingRulesTab.vue — 移除并发上限控件

- [x] 3.1 删除「人设并发上限」`el-form-item`（line 16-21）；「门控超时」/「超时兜底路由」保留；divider「开口前门控 (gating)」保留（下挂两项）。
<!-- isales-web 0bb40eb — 移除 el-form-item，留注释指向 persona 卡。 -->

## 4. 测试

- [x] 4.1 `promptTierEditor.test.ts`：开关开/关 ↔ `update:personaFanoutCap` 1↔2 映射；开时露出并发上限控件并能调 2/3；cap-check 用 model 值。
- [x] 4.2 `routingRulesTab.test.ts`：断言不再渲染并发上限控件 + 门控超时仍在。
- [~] 4.3 `campaignDetail.test.ts`：PromptTierEditor 被 stub，v-model 接线是模板编译层、无独立可测行为；emit↔cap 映射已由 4.1 覆盖 → **本文件无需改**（且该文件当前正被并发 interruption session 改动，不属本 change）。
- [x] 4.4 我的 3 测试文件 vitest 全绿（promptTierEditor 12 + routingRulesTab 8）；lint 我的 4 文件 exit 0；typecheck 我的文件无错。
<!-- 注：仓库级 vitest/vue-tsc 当前因并发 interruption-min-chars-and-mode-toggle WIP（interruptionRuleEditor.test.ts 函数签名漂移 + 打断改名 → campaignDetail.test.ts 期望「打断保护」失败）整体非绿；与本 change 无关，属并发 session 收口范围。 -->

## 5. 收口

- [x] 5.1 `openspec validate web-admin-persona-enable-toggle --strict` 通过。
- [x] 5.2 commit（isales-web `0bb40eb`）+ push origin（85a6c1f..0bb40eb）。
- [ ] 5.3 web 部署（`npm run build` → rsync dist → nginx reload）+ 浏览器抽验（开/关切换、刷新回显、门控路由不再有并发上限）。**DEFERRED**：工作树被并发 interruption WIP 污染（`vue-tsc --noEmit` 因 interruptionRuleEditor.test.ts 报错而 build 不过），无法从当前树产出干净 dist。待并发 session 收口 / 树干净后再 build+deploy。
- [ ] 5.4 archive：`openspec archive web-admin-persona-enable-toggle`，merge delta 到 `specs/web-admin-ui/`；meta-repo commit + push。**待 5.3 部署+抽验后再做。**
