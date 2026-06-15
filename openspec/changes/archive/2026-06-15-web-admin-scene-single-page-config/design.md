## Context

场景配置当前分裂:`CampaignDetail.vue`(客户向:进度 / 基本信息含 greeting TTS 试听 / 可拨时段 / 3 个 PromptTier AI 角色卡 + FillerEditor / sticky 保存条,form 仅 8 字段子集)+ `CampaignEdit.vue`(13-tab 全字段高级编辑器,统一 `form: CampaignBase` + roleConfigs/fillerSets/callbackConfigs + buildPayload/onSave/applyFieldErrors),后者经 `operations-campaign-edit` 路由 + 详情页「高级配置」按钮进入。

**两套并存的存储模式**(本 change 的核心约束):
- **自包含组件**:`PromptTierEditor`(×3,按 `:campaign-id`+`kind` 各自 CRUD role_config)+ `FillerEditor`(按 `:campaign-id` 自存)——它们**不**经 form/buildPayload。
- **form-driven**:`CampaignEdit` 的其余 tab 全 v-model 一个 `form` + 一个 buildPayload 统一存。

上次大改版 `web-admin-one-role-ia-consolidation`(已部署、未 archive)解散了运营/客户二分,但 **D6 明确把 CampaignEdit 折叠 deferred 到「引擎定型后另起 change」**——本 change 即兑现 D6。引擎已定型(gate-first + §11 上线)。

## Goals / Non-Goals

**Goals:**
- `CampaignDetail` 成为场景**唯一**配置页,所有设置能力**全展开、纵向铺排**(用户决定:不折叠)。
- 新增 9 个 form-driven 小节(Routing/Tools/Silence/Interruption/Transfer/WrapUp/Retry/DoNotCall/Callbacks),复用现有 Tab 组件。
- 保留 3 个 PromptTier 卡 + FillerEditor + 基本信息(含 TTS 试听)+ 可拨时段(均现有内联,不双份)。
- 删 `CampaignEdit` + `operations-campaign-edit` 路由 + 「高级配置」跳转。
- 清过期文案。

**Non-Goals:**
- 不动 api / engine / schema / 数据契约。
- 不做 persona / restructure 配置卡(弃 RoleConfigTab 的连带缺口,用户已知悉)。
- 不改实时监控 / 回调独立编辑页。
- `PromptTierEditor` 组件/类型改名 defer(内部命名 churn、非用户可见文案)。

## Decisions

### D1：CampaignDetail 作宿主,form 扩成完整 CampaignBase
把详情页 `form`(8 字段)扩成 `reactive<CampaignBase>`,`onRefresh` 全量 `Object.assign(form, detail)`。新增 9 个 form-driven 小节直接 v-model `form`。
- **理由**:详情页已是客户向落点 + 有 chrome(进度/启停/监控);把高级能力铺进来比反向把 chrome 搬进 CampaignEdit 干净。

### D2：两套存储模式并存,不强行统一
PromptTier 卡 + FillerEditor 继续按 `campaign-id` **自存**(各自保存按钮);9 个 form-driven 小节走详情页**统一 buildPayload/onSave**。buildPayload **不含** role_configs / filler_sets(它们自存)。
- **理由**:统一两套存储会改 PromptTier/Filler 组件契约,放大风险;并存是最小改动。代价:页面有两类保存动作(角色/垫词即时存,其余经底部保存条)——保存条文案需说明。
- 新增**只读 `roleConfigs` ref**:`onRefresh` 时 `detail.role_configs` 灌入,仅供 Routing/Tools 小节取 referee label(不参与保存)。角色编辑后 referee label 变化需刷新页面同步——可接受(label 极少中途改)。

### D3：避免双份编辑同一字段
基本信息 / 可拨时段 / AI 角色 / filler **已在详情页内联** → **不**引入 BasicTab/TimeWindowTab/RoleConfigTab/FillerTab。仅引入 9 个尚未内联的小节。
- **理由**:防止同一字段两处可编辑导致脏写/困惑。greeting TTS 试听因此原样保住(本就在详情页内联)。

### D4：删除独立高级编辑器,旧链接走 not-found
删 `CampaignEdit.vue` + `operations-campaign-edit` 路由 + 「高级配置」按钮 + `goAdvanced()`。旧 `/operations/campaigns/:id/edit` 走 not-found(运营区已解散、无重定向,沿用 one-role-ia 既定预期)。

### D5：弃 RoleConfigTab → persona/restructure 缺口(用户已拍)
保留 3 个 PromptTier 卡(main/referee/extractor),不做 persona/restructure 卡。RoutingRulesTab 的「路由到 persona」仍引用 persona label,但本页无创建入口(默认 N=1 用不到)。后续真用再补同款卡。

## Risks / Trade-offs

- **[主力管理功能,改错即崩编辑流]** → 分步实施(见 tasks);保存 payload + 关键小节加单测;手测 + 灰度。
- **[form 从 8 字段扩到 ~30 字段]** → 用 `CAMPAIGN_DEFAULTS` 初始化 + `onRefresh` 全量 assign;字段缺失会丢配置,需逐一核对 CampaignBase 覆盖。
- **[两套保存模式易困惑]** → 保存条文案明确「基本信息/路由/工具/沉默/转人工/收尾/调度 等改动需保存;AI 角色与垫词各自即时保存」。
- **[一页过长]** → 用户明确要全展开;以清晰小节标题 + 锚点/分隔缓解;暂不折叠。
- **[roleConfigs ref 与 PromptTier 自存不实时同步]** → label 中途改后需刷新;可接受。
- **[过期文案]** → 7 处一并清(见 tasks);PromptTier 组件改名 defer。

## Migration Plan

1. 扩 `CampaignDetail.form` → CampaignBase + onRefresh 全量;不破坏现有 basic/时段/PromptTier/filler 小节。
2. 合并 buildPayload/applyFieldErrors 进 onSave;加只读 roleConfigs ref。
3. 逐个加 9 个 form-driven 小节(每加一个 build + 手测保存)。
4. 删「高级配置」按钮/goAdvanced;删路由 + import;删 `CampaignEdit.vue`;迁移/删 `campaignEdit.test.ts`。
5. 清过期文案。
6. `npm run build` + vitest + lint 全绿 → 部署 web(rsync dist + nginx reload)→ 更 STATE.md。
- **回滚**:rsync 回旧 dist + nginx reload(秒级)。

## Open Questions

- **与 `web-admin-one-role-ia-consolidation` 的 spec 协调**:该 change(已部署未 archive)也改 web-admin-ui 的 view 清单 / 运营区收纳。本 change 的 spec delta 走 **ADDED**(对当前 merged base 合法);二者 archive 时需 reconcile「场景配置 IA」段。建议 archive 顺序:one-role-ia 先,本 change 后。
- 底部统一保存条 vs 每小节独立保存——本次统一(除 PromptTier/Filler 自存);未来可全统一。
- web-admin-ui spec 中 referee prompt 编辑器提示「referee 必须输出严格 JSON {decision, goal_type, confidence}」**已过期**(referee 现为裸 token)——属 PromptTier 编辑器文案,本 change 不动(留给引擎侧 spec/编辑器后续),仅在此记录。
- persona/restructure 卡是否后续补 + CallbacksTab 保持只读跳转(本次保持)。
