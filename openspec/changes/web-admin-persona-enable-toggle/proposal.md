## Why

`web-admin-persona-panel-and-main-lock`（已 archived 2026-06-09）兑现了 persona 配置卡，但卡头那个 `el-switch`（active-text="展开" / inactive-text="收起"）当前**只是一个纯前端折叠开关**——绑定本地 `expanded` ref、只控制 `v-if="open"` 的显隐，既不落库也不影响引擎；真正决定功能开/关的 `persona_fanout_cap`（1=关、2/3=开）反而藏在另一个区域「门控路由 → 人设并发上限」(`RoutingRulesTab`)。用户看到卡头开关，合理预期它能**真的启用/关闭多人设推测**，结果它什么功能都不管——开关语义与用户心智不符，且功能控件与卡分散在两处。

引擎侧早已只认 `campaign.persona_fanout_cap`（`run_loop.py`：`enabled_personas = personas[:cap-1]`，cap=1 时不起任何 persona），api 也已透传该字段。所以「让卡头开关真生效」是一个**纯前端重接线**：把开关绑到 `persona_fanout_cap`，并把并发上限选择器从「门控路由」迁入 persona 卡，开/关与并发级别同处一卡。

## What Changes

- **卡头开关 = 真功能开关**（web-admin-ui）：persona 卡头的开关由"纯展开/收起"改为绑定 `persona_fanout_cap`——关→写 `persona_fanout_cap=1`（仅 main、无推测），开→写 `persona_fanout_cap≥2`（从 1 切开时默认置 2）。卡体的展开/收起跟随该开关（开=展开可配，关=收起）。
- **并发上限控件迁入 persona 卡**（web-admin-ui）：把「人设并发上限」(2/3) 数字控件从「门控路由」配置区迁入 persona 卡卡体，仅在开关为「开」时显示，取值 clamp [2,3]；从 `RoutingRulesTab` 移除该控件（routing_rules 仍引用 persona label，不动）。
- **单一真相、零冗余**（设计决策）：复用已有的 `persona_fanout_cap` 作为开/关的唯一承载，**不新增** `persona_enabled` 布尔列、**不动** common / engine / api——避免 `cap=1` 与 `enabled=false` 两处「关」语义的冗余（对齐「多层兜底是问题味道」）。
- **cap-check 提示同步**：persona 行超 cap 启用时的提示由"请调高「门控路由 → 人设并发上限」"改为指向本卡内的并发上限控件。

## Capabilities

### New Capabilities
<!-- 无新增 capability —— 纯前端重接线已设计好的 persona_fanout_cap 控件语义。 -->

### Modified Capabilities
- `web-admin-ui`: 「persona 推测并发上限（persona_fanout_cap）配置控件」requirement 由"控件位于「多流路由」配置区的数字步进器、卡头开关仅作页面折叠"改为"卡头开关即功能开关（关=cap 1 / 开=cap 2-3）、并发上限数字控件迁入 persona 卡卡体"。无后端 / 数据契约 / 引擎行为变更。

## Impact

- **isales-web**（唯一受影响仓）：
  - `components/Campaign/PromptTierEditor.vue`：`personaFanoutCap` 由只读 prop 改为双向（`defineModel`）；collapsible 卡的 `open` 由本地 `expanded` ref 改为派生自 `fanoutCap > 1`；卡头开关 v-model 改绑功能开关 computed；卡体新增「人设并发上限」(2/3) 控件；cap-check 提示文案更新。
  - `views/Campaigns/CampaignDetail.vue`：persona 卡 `:persona-fanout-cap` 改为 `v-model:persona-fanout-cap`；卡 description + HTML 注释更新。
  - `views/Campaigns/Tabs/RoutingRulesTab.vue`：移除「人设并发上限」el-form-item（门控超时 / 超时兜底路由保留）。
  - 测试：`promptTierEditor.test.ts` / `routingRulesTab.test.ts` / `campaignDetail.test.ts` 相应更新。
- **后端无改动**（已核实）：引擎 `run_loop.py` 已只认 `persona_fanout_cap`；`CampaignUpdate.persona_fanout_cap` 已暴露并可 PATCH。**无 alembic / engine / api / common 改动。**
- **部署**：web only（`npm run build` → rsync dist → nginx reload）。
- **风险低**：opt-in 默认 `persona_fanout_cap=1`（开关回显为「关」）行为不变，存量 campaign 向后兼容；唯一可见变化是并发上限控件从「门控路由」移到 persona 卡内。
- **关联**：叠在 `web-admin-scene-single-page-config` 单页骨架 + 已 archived `web-admin-persona-panel-and-main-lock` 之上。
