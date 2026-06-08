## Why

The web admin carries a vestigial **operations-vs-customer split**: a `/operations/*`
section (运营管理) with its own landing grid duplicates customer-facing功能 that already
live in the business nav (任务管理 ↔ 场景, plus a second campaign editor reached by a
cross-section "高级配置" jump). The system has **exactly one role — every authenticated
account is a 用户**; there is no operator-vs-customer audience. The split breeds duplicate
pages, two divergent campaign editors (one of which is partially broken), dead-stub views
for未实装 backends, and confusing navigation. This change dissolves the split into a single
unified IA so each capability has **one home**, on the customer-facing design language.

## What Changes

- **BREAKING (IA/nav)**: dissolve the entire `/operations/*` section and the `OperationsIndex`
  landing page; remove the「运营管理」nav entry. Navigation becomes a single `TopNav`
  (customer design language: pills + 圆按钮 + user menu, no sidebar).
- **Migrate overlaps to the customer surface**: 数据看板 (DashboardView) becomes a customer
  top-level `/dashboard` pill (global aggregate the customer面 never had); 任务管理
  (CampaignList) is **removed** as a full duplicate of 场景 (CampaignWorkspace).
- **Collapse rare-but-real features** (backends confirmed in `isales-api/routers/`) into a
  "更多/设置" fold-away area on the customer nav: 通话监控 (MonitorView / ws), 转人工任务
  (HandoffTaskList / handoff_tasks), 节假日 (HolidayList / holidays), 设备在线状态
  (edge-devices, read-only liveness), 音色目录 (VoiceModelList / voice_models — also surfaced
  as a `voice_id` picker on campaign config).
- **Delete outdated dead-stub pages** (no backend): SIM 卡 (SimCardList), 回调记录
  (CallbackLogList), 回调配置独立页 (CallbackConfigList → folded into the per-campaign 回调 tab).
- **Fix a dead route en passant**: `CallbacksTab.vue` pushes `callback-config-edit`, a name
  the router never defines — rewire it to open callback editing inside the campaign tab.
- **Add the one missing customer affordance**: 场景 卡片 gains a「删除场景」action
  (CampaignWorkspace currently has no delete) — a hard prerequisite before removing CampaignList.
- **Preserve the customer design language** (STYLE_GUIDE.md, `--isales-*` tokens) throughout;
  no new visual system, only relocation + fold-away.

### Deferred (explicitly NOT in this change)

- **campaign 配置内部** (referee `label` / `routing_rules` / role config / gating exposure):
  the engine is being redesigned and the product decision is "客户面不露 label/routing". This
  change keeps the existing campaign-config editor as-is (it stays reachable from场景详情) and
  does NOT restructure it; a follow-up change redesigns it on the customer理念 once the engine
  settles.
- **callback 后端 admin CRUD** (`impl-callback-admin-api` not landed): callback stays
  per-campaign only; the standalone admin pages are removed, not reimplemented.

## Capabilities

### New Capabilities
<!-- None — this is an IA/navigation reorganization of existing views, not a new domain capability. -->

### Modified Capabilities
- `web-admin-ui`: the「运营面 view 收纳」requirement (a separate operations area) and the
  「顶级信息架构」requirement (operations-vs-customer two-zone nav) change to a **single-role
  unified IA** — operations zone dissolved, overlaps migrated to the customer nav, rare features
  folded away, dead-stub views removed. The「客户面 view 清单」requirement gains 数据看板 as a
  top-level entry and 删除场景 on the 场景 list.

## Impact

- **isales-web only** (no backend/API/contract changes): `router/index.ts` (remove ~11
  `operations-*` routes + `OPERATIONS_REDIRECTS` cleanup; add `/dashboard`), `components/TopNav.vue`
  (drop运营管理 entry, add /dashboard pill + fold-away area), `views/Operations/OperationsIndex.vue`
  (delete), `views/Campaigns/{CampaignWorkspace,CampaignList,CampaignDetail}.vue`, the
  Callbacks/Devices/SimCards/Monitor/HandoffTasks/Holidays/VoiceModels views (delete or re-home),
  `Tabs/CallbacksTab.vue` (dead-route fix).
- **Backends unchanged**: all migrated/collapsed features (analytics / ws / handoff_tasks /
  holidays / voice_models / edge_devices) keep their existing API contracts; only the deleted
  stubs (sim, callback-logs, standalone callback-configs) had no backend to begin with.
- **Acceptance**: `make spec-validate`; vitest (router guards / `isActive` / nav render);
  `npm run check:routes` (no dangling push names); manual no-404 sweep of every rewired inbound ref.
