# Tasks — web-admin-one-role-ia-consolidation

> 全程 isales-web only，无后端改动。每批一个独立可上线 commit（design D5）。
> 客户面保持 STYLE_GUIDE.md 设计语言，token 用 `--isales-*`。

## 0. 前置盘点（开工前核实）

- [x] 0.1 复核全量 `operations-*` 路由 + `OPERATIONS_REDIRECTS` 当前清单（`src/router/index.ts`），确认本 change 删除/保留集与 design D2 一致。
- [x] 0.2 复核每个被删/迁 view 的后端：`analytics`/`ws`/`handoff_tasks`/`holidays`/`voice_models`/`edge_devices` 有后端→迁/折叠；`sim_cards`/独立 callback admin 无后端→删（对照 `../isales-api/isales_api/routers/`）。
- [x] 0.3 grep 全量 inbound refs 到将删路由名，建立「删前必改」清单（`TopNav.vue:108`、`OperationsIndex.vue` 卡片、`CampaignList.vue:97`、`CampaignDetail.vue:358`、`CallbackConfigEdit.vue:30`、`CallbacksTab.vue:66,73`）。
<!-- §0 ground-truthed via workflow wf_e212534a + 直接 grep isales-api/routers (2026-06-08，propose 前已做)。 -->


## 1. Batch 1 — 纯新增，零删除（先让客户面够用，回滚成本最低）

- [x] 1.1 `CampaignWorkspace.vue`：场景卡片加「删除场景」动作 + 二次确认弹窗，调 `campaignsApi.remove`，成功后从列表移除。（满足 spec「场景列表可删除场景」Scenario；是 §3 删 CampaignList 的硬前置。）
- [x] 1.2 `router/index.ts`：新增客户顶级路由 `/dashboard`（name `dashboard`），复用 `views/DashboardView.vue` 组件（不动组件本身）；摘掉 `OPERATIONS_REDIRECTS` 里 `/dashboard` 重定向。
- [x] 1.3 `TopNav.vue`：主 pills 增加「数据看板」第五入口（场景/线索/外呼/预约/数据看板），`LayoutDashboard` 图标；`isActive()` 由 `current === name` 覆盖 `dashboard`。
- [x] 1.4 campaign `voice_id` 输入接 `voiceApi.list()` 做 filterable + allow-create 选择器（`CampaignDetail.vue` 基本信息区）；allow-create 保留手填 vendor voice id 兜底。
- [x] 1.5 Batch 1 自测：`npm run typecheck` + `check:routes`(23 路由) + `vitest`(51) + eslint 全绿。
<!-- web 7c60a00 (2026-06-08) — Batch 1 全部落地，纯新增零删除。campaignsApi.remove(id) 即删除方法；
     voiceApi.list() 返回 {id,name,voice_id}[]。手测留待 §5.3 统一回归（或部署后）。 -->


## 2. Batch 2 — 折叠区落地 + 低频项迁入 + 回调收口（仍不删主能力）

- [ ] 2.1 `TopNav.vue`：用户菜单（el-dropdown）或齿轮圆钮新增「更多/设置」折叠分组，沿用 `--isales-*` token，不新造视觉。（满足 spec「更多折叠区展开低频 view」Scenario。）
- [ ] 2.2 把 通话监控 `MonitorView` / 转人工 `HandoffTaskList` / 节假日 `HolidayList` / 设备在线状态 edge-devices / 音色目录 `VoiceModelList` 的入口收入「更多/设置」折叠区（route 归属调整，组件文件保留）。
- [ ] 2.3 通话监控：修掉 `campaign_id='0'` 占位入口；在 `CampaignDetail` / `CallDetail` 加就近「实时监控」入口（更符合用户心智）。
- [ ] 2.4 回调收口到 per-campaign「回调」tab：`CallbacksTab.vue` 修断路由 `callback-config-edit`（router 无此 name）→ 改为 tab 内弹层打开 `CallbackConfigEdit` 子表单；`CallbackConfigEdit.vue:30` 返回改为回 campaign 回调 tab / `router.back`。
- [ ] 2.5 Batch 2 自测：typecheck + check:routes（无断名，含修掉的 `callback-config-edit`）+ vitest 全绿；手测折叠区每项可达、回调 tab 内编辑闭环。

## 3. Batch 3 — 删运营 dup + 空壳页（破坏性，放最后）

- [ ] 3.1 删 `views/Campaigns/CampaignList.vue` + 路由 `operations-campaigns`（场景列表已覆盖 + 1.1 已补删除场景）。
- [ ] 3.2 删 `views/Operations/OperationsIndex.vue` + 路由 `operations-index`；删 `TopNav.vue:108` `goOperations()` + 「运营管理」菜单项。
- [ ] 3.3 删空壳页（无后端）：`views/SimCards/SimCardList.vue` + 路由 `operations-sim-cards`；`views/Callbacks/CallbackLogList.vue` + 路由 `operations-callback-logs`；`views/Callbacks/CallbackConfigList.vue` + 路由 `operations-callback-configs`（回调已收口为 campaign tab，§2.4）。
- [ ] 3.4 `router/index.ts`：清理 `OPERATIONS_REDIRECTS` 中指向已删路径的 301 项；`/dashboard` 不再重定向（已是正式客户路由，§1.2）；保留仍存在目标的兼容项。
- [ ] 3.5 收尾 inbound-ref 扫描：grep 全仓确认无残留指向已删路由名的 push/router-link；`check:routes` 绿。
- [ ] 3.6 Batch 3 自测：typecheck + check:routes + vitest 全绿；手测每个旧运营路由不再 404 到死页（要么重定向、要么入口已移除）。

## 4. Batch 4 — 陈旧文案/组件清理（低风险，可并行/后置；engine-spec-terminology-purge 前端尾巴）

- [ ] 4.1 删 `CampaignEditDialog` 等处「润色 / polish」9-tab 残留 banner 文案（润色 tier 已废）。
- [ ] 4.2 `CampaignDetail.vue:160-187`「AI 外呼策略：4-tier 并行配置」块文案收口为现行 dual-LLM 表述（不动 campaign 配置内部结构——那属 DEFERRED）。
- [ ] 4.3 `PipelineTracePanel` 单 referee 渲染 → N referee + restructure 模型（若涉及 referee 语义重构则与引擎重设计 change 协调，纯展示文案可先改）。
- [ ] 4.4 `PromptTier*` 命名层评估重命名为 `RoleConfig*`（仅命名/术语，不改行为；如牵动 deferred 配置编辑则留给后续 change）。

## 5. 验收

- [ ] 5.1 `make spec-validate`（`openspec validate --specs && --changes`）通过。
- [ ] 5.2 isales-web：`npm run typecheck` + `npm run lint` + `npm run check:routes` + `npm run test` 全绿。
- [ ] 5.3 手测：登录后无「运营管理」入口；五主入口 + 模型厂商 + 更多/设置 全可达；每个折叠项、回调 tab、删除场景、/dashboard 正常；旧运营链接无死 404。
- [ ] 5.4 部署：`npm run build` → `rsync -az --delete dist/` → `/var/www/isales-web/` → `nginx -s reload`（SPA 200）；按 [[reference_state_files]] 更新 `deploy/cloud/STATE.md`。
- [ ] 5.5 回写本 tasks.md（HTML 注释标 PR#/commit/偏离）；DEFERRED 项（campaign 配置内部 referee/routing 客户化、callback 后端 admin CRUD）记录在 design 已注明，留待后续 engine-gated change。
