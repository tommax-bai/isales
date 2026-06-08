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

- [x] 2.1 `TopNav.vue`：用户菜单（el-dropdown）新增「更多/设置」二级分组（替换原「运营管理」项），沿用 `--isales-*` token，不新造视觉。（满足 spec「更多折叠区展开低频 view」Scenario。）
- [x] 2.2 把 转人工 `HandoffTaskList` / 节假日 `HolidayList` / 设备在线状态 edge-devices / 音色目录 `VoiceModelList` 的入口收入「更多/设置」折叠区（组件文件保留；路由名暂用 operations-*，clean path 在 §3 重命名）。
- [x] 2.3 通话监控：`CampaignDetail` 加就近「实时监控」入口（→ operations-monitor 带 campaign id），替代原运营区 `campaign_id` 占位入口。（监控需 campaign_id，不进 §2.1 平铺折叠菜单。）
- [x] 2.4 回调断路由修复：`CallbacksTab.vue` `callback-config-edit`（router 无此 name）→ `operations-callback-config-edit`（真实路由，2 处）；`CallbackConfigEdit.vue:30` onBack → `router.back()`（健壮，list 页 §3 删）。**回调真编辑（in-tab 表单）blocked on callback 后端 admin CRUD，本批仅修断路由。**
- [x] 2.5 Batch 2 自测：typecheck + check:routes(23) + vitest(51) + eslint 全绿。
<!-- web 988d3d0 (2026-06-08) — Batch 2 非破坏：更多/设置折叠区 + 监控就近入口 + 回调断路由修。
     OperationsIndex 随「运营管理」入口移除变 nav 孤儿（§3 删文件）。CallbackConfigEdit 是 stub
     banner（无真表单），真回调编辑等后端 admin CRUD。 -->


## 3. Batch 3 — 删运营 dup + 空壳页（破坏性，放最后）

- [x] 3.1 删 `views/Campaigns/CampaignList.vue` + 路由 `operations-campaigns`（场景列表已覆盖 + 1.1 已补删除场景）。
- [x] 3.2 删 `views/Operations/OperationsIndex.vue` + 路由 `operations-index`；`TopNav.vue` `goOperations()` + 「运营管理」菜单项已在 §2.1 移除。
- [x] 3.3 删空壳页（无后端）：`SimCardList.vue` + `operations-sim-cards`；`CallbackLogList.vue` + `operations-callback-logs`；`CallbackConfigList.vue` + `operations-callback-configs`（回调收口为 campaign tab）。
- [x] 3.4 `router/index.ts`：移除整套 `OPERATIONS_REDIRECTS` + `/monitor` 特判重定向（运营区解散，旧 `/operations/*` 走 not-found，不留永久兜底 shim）。保留 view 路由从 `operations-*` 重命名到干净路径（monitor/handoff-tasks/holidays/devices/voice-models/callback-config-edit）。**CampaignEdit 按 D6 保留 `operations-campaign-edit`**（引擎 deferred）。
- [x] 3.5 收尾 inbound-ref 扫描：grep 确认仅剩 `operations-campaign-edit`（D6 保留，router 定义 + CampaignDetail goAdvanced 2 处），其余运营路由名全清。
- [x] 3.6 Batch 3 自测：typecheck + check:routes(23→17) + vitest(51) + eslint 全绿。
<!-- web f1d15d2 (2026-06-08) — Batch 3 破坏性：删 5 view（净 ~600 行）+ 删 6 死路由 + 重命名 6
     保留路由 + 移除 redirect 机制。唯一 operations- 残留是 D6 deferred CampaignEdit。手测旧链接
     404/新链接可达留待 §5.3 统一回归或部署后。 -->


## 4. Batch 4 — 陈旧文案/组件清理（低风险，可并行/后置；engine-spec-terminology-purge 前端尾巴）

- [x] 4.1 删死组件 `components/Campaign/CampaignEditDialog.vue`（无 import；stale PR#3 banner 含润色/裁判/9-tab）。`types/call.ts:39` 的 "was judge_results/polish_*" 是合法历史迁移注释，保留。
- [x] 4.2 `CampaignDetail.vue`「AI 外呼策略：4-tier 并行配置」注释收口为 dual-LLM（主对话/决策/抽取）；不动 campaign 配置内部结构（DEFERRED）。
- [~] 4.3 **DEFERRED → 引擎后续 change**：`PipelineTracePanel` 单 referee(`referee_decision/goal_type/confidence`) → N referee 数组 + restructure。非纯术语——牵涉 pipeline_trace 数据契约 + referee 语义（引擎正在动）。
- [~] 4.4 **DEFERRED → 引擎后续 change**：`PromptTier*` → `RoleConfig*` 重命名。`PromptTierEditor` 是 deferred 客户配置编辑器，引擎后续大概率整体重做/替换，现在改名是 churn。
<!-- web 0301e80 (2026-06-08) — Batch 4 仅做死透术语（4.1 删死 dialog + 4.2 destale 注释）。
     4.3/4.4 defer：均在引擎正在重塑的 referee/trace/配置编辑区，符合 design 风险注记 + 用户 referee deferral。 -->


## 5. 验收

- [x] 5.1 `openspec validate web-admin-one-role-ia-consolidation --strict` 通过。
- [x] 5.2 isales-web：`typecheck` + `lint`(全量) + `check:routes`(17) + `test`(51) 全绿。
- [~] 5.3 ref 完整性已自动验证（grep 全仓仅剩 D6 `operations-campaign-edit`；`check:routes` 无悬空 push name）。**真人点测留给用户**——已部署上线，旧 `/operations/*` 走 not-found（无重定向）符合预期。
- [x] 5.4 部署：`build`(60 assets) → `rsync -az --delete dist/` → `/var/www/isales-web/` → `nginx -s reload`，SPA 200（2026-06-08 11:55 CST）；`deploy/cloud/STATE.md` 已更新（见顶部条目）。
- [x] 5.5 tasks.md 全程回写（§0–§4 HTML 注释带 commit）；DEFERRED 项（campaign 配置内部 referee/routing 客户化、§4.3 PipelineTrace 多裁判渲染、§4.4 PromptTier 改名、callback 后端 admin CRUD）design 已注明，留待 engine-gated 后续 change。
<!-- 部署 web only，无 api/alembic。change 实施完成（§4.3/4.4 deferred）；archive 可在引擎后续
     change 合并 campaign-config 客户化时一并评估，或本 change 现状即可 archive（IA 收口已达成）。 -->

