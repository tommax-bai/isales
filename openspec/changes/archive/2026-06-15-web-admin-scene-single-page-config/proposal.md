## Why

场景(campaign)配置目前分裂成两处:客户向的 `CampaignDetail`(进度 + 基本信息 + 可拨时段 + 3 个 AI 角色卡)+ 一个 13-tab 的高级编辑器 `CampaignEdit`,后者只能经「高级配置」按钮跳到独立路由 `operations-campaign-edit`。这是上次 web 大改版(`web-admin-one-role-ia-consolidation`)**明确 deferred 的 D6**——当时引擎在重构(gate-first 未定),所以没把高级编辑器折进详情页。现在引擎已定型(gate-first + §11 上线),应兑现这个「另起 change」:把全部设置能力**一页到底**铺在场景详情页,单角色、无 tab、无跳转;并清理残留的过期文案。纯 UI / IA 重构,不改 api / engine / 数据契约行为。

## What Changes

- **场景详情一页到底**(web-admin-ui):`CampaignDetail` 成为场景的**唯一**配置页,所有设置能力**全部展开、纵向铺排**(用户决定:不折叠)。复用现有 Tab 组件作内联小节,新增 9 个 form-driven 小节:**多流路由 / 工具触发 / 沉默激活 / 打断保护 / 转人工 / 收尾 / 重试·跟进 / 勿打 / 回调**。
- **保留现有内联能力**:基本信息(含 greeting TTS 试听)、可拨时段、**3 个 PromptTier AI 角色卡**(main/referee/extractor)+ FillerEditor——这些**不**用对应 Tab 组件替换(避免双份编辑同一字段)。用户决定:AI 角色保留 PromptTier 卡,**弃** RoleConfigTab 表格版。
- **状态/保存合并**:`CampaignDetail.form` 从 8 字段扩成完整 `CampaignBase`;`onRefresh` 全量加载;合并 `CampaignEdit` 的 `buildPayload`(greeting 归一、omit callback_configs)+ `applyFieldErrors`(422) 进 `onSave`。**不含 role_configs/filler_sets**(PromptTier/Filler 卡按 `campaign-id` 自存,两套存储模式并存)。新增只读 `roleConfigs` ref 供路由/工具小节取 referee label。
- **删除**(BREAKING 限前端导航):`CampaignEdit.vue` 整文件 + `operations-campaign-edit` 路由 + `CampaignDetail` 的「高级配置」按钮 + `goAdvanced()`(仅 2 处 inbound ref)。
- **清过期文案**:`CampaignDetail` 注释「4-tier/三层」「原运营区」、`RoleConfigDialog` placeholder「main_judge」→「main_referee」、随路由删除的「operations-campaign-edit」名 + D6 注释、`campaignEdit.test.ts` 的「main_judge」fixture(随测试删除迁移)。
- **persona/restructure 缺口**(用户已知悉):弃 RoleConfigTab → 暂无 persona/restructure 配置入口(gate-first 高级/opt-in,默认 N=1 用不到;RoutingRulesTab 的「路由到 persona」仍引用其 label)。本次先留 3 卡,后续真用再补同款卡。

非目标:不动 api/engine/schema;不做 persona/restructure 卡;不改实时监控 / 回调独立编辑页;`PromptTierEditor` 组件/类型改名(内部命名 churn、非用户可见文案)defer。

## Capabilities

### New Capabilities
<!-- 无新增 capability —— 纯 IA/表现层重排,复用现有 campaign 配置能力。 -->

### Modified Capabilities
- `web-admin-ui`: 场景配置 IA 由「客户向详情页 + 经『高级配置』跳转的 13-tab 高级编辑器」改为「**场景详情一页到底**,全部设置能力纵向铺排在单页」;删除独立高级编辑器路由与跳转入口;过期文案清理。无后端/数据契约行为变更。

## Impact

- **isales-web**(唯一受影响):
  - `views/Campaigns/CampaignDetail.vue`:扩 `form` 到完整 `CampaignBase` + 新增 9 个 form-driven 小节(import 对应 Tab 组件)+ 合并 buildPayload/applyFieldErrors + 新增只读 roleConfigs ref + 删「高级配置」按钮/goAdvanced + 文案清理。
  - `views/Campaigns/CampaignEdit.vue`:**删除**。
  - `router/index.ts`:删 `operations-campaign-edit` 路由 + import + D6 注释。
  - `components/Campaign/RoleConfigDialog.vue`:placeholder 文案。
  - `tests/campaignEdit.test.ts`:删除;`tests/campaignDetail.test.ts`(新增/扩展):保存 payload + 小节渲染单测。
- **部署**:web only,`npm run build` → `rsync -az --delete dist/` → `/var/www/isales-web/` → `nginx -s reload`。**无 api / alembic / engine 改动**。
- **风险**:场景配置是主力管理功能;两套存储模式并存 + form 扩字段 + 保存合并需谨慎;greeting TTS 试听必须保住;旧 `/operations/campaigns/:id/edit` 链接走 not-found(运营区已解散,无重定向,符合既定预期)。
- **回滚**:web 纯前端,rsync 回旧 dist + nginx reload(秒级)。
