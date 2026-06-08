## Context

`isales-web` today splits navigation into two zones: a customer-facing business nav
(场景 / 线索 / 外呼 / 预约 + 模型厂商) and a separate **运营管理** area at `/operations/*`
with its own `OperationsIndex` landing grid (10 cards). The `web-admin-ui` spec's
「运营面 view 收纳」requirement codifies this split and even mandates 301 redirects from
old top-level paths into `/operations/*`.

This two-zone model is a holdover. The product has **one role** — every authenticated user
is the same persona; there is no separate "operator". The split has produced concrete debt:

- **Full duplication**: 任务管理 (`CampaignList`) duplicates 场景 (`CampaignWorkspace`) on the
  same `campaignsApi`; a second campaign editor (`CampaignEdit`) is reachable only by a
  cross-zone「高级配置」jump added as a stopgap.
- **Dead stubs**: a ground-truth pass over `isales-api/routers/` shows **no backend** for
  SIM 卡, callback-logs, or a standalone callback-admin CRUD — those operations views are shells.
- **Real-but-misplaced features**: `analytics` (数据看板), `ws` (通话监控), `handoff_tasks`,
  `holidays`, `voice_models`, `edge_devices` (read-only liveness) all **have real backends** but
  are buried in the operations zone, invisible to the single user.
- **A dead route**: `CallbacksTab.vue` pushes `callback-config-edit`, a name the router never
  defines.

## Goals / Non-Goals

**Goals:**
- Dissolve the operations/customer split into **one unified nav** on the existing customer
  design language (pills + 圆按钮 + user menu; STYLE_GUIDE.md, `--isales-*` tokens). No new
  visual system.
- Every capability has exactly **one home**: overlaps migrated to the customer surface, rare
  features folded into a "更多/设置" area, dead stubs deleted.
- No dangling navigation: every inbound ref to a removed route is rewired or removed;
  `npm run check:routes` stays green.
- Backends untouched — pure front-end IA reorganization.

**Non-Goals:**
- **campaign 配置内部 redesign** (referee `label` / `routing_rules` / role / gating exposure on
  the customer surface). The engine is mid-redesign and the product rule is "不露 label/routing";
  restructuring the campaign editor is a separate, engine-gated change. This change keeps the
  existing campaign-config editor functioning and reachable, unchanged.
- Re-implementing missing backends (callback admin CRUD) — the stub pages are removed, not rebuilt.
- Backend / API / contract changes of any kind.

## Decisions

**D1 — Dissolve `/operations/*` entirely; single TopNav.** Remove `OperationsIndex` and the
「运营管理」menu entry. The「运营面 view 收纳」requirement is removed; the「顶级信息架构」
requirement gains a 5th main pill (数据看板) and a fold-away "更多/设置" area for rare features.

**D2 — Disposition per feature** (driven by ground-truthed backend existence):
- *Migrate to a customer top-level pill*: 数据看板 → `/dashboard` (analytics backend; the customer
  surface never had a global aggregate).
- *Delete as duplicate*: 任务管理 `CampaignList` (场景 covers it).
- *Delete as dead stub* (no backend): SIM 卡, 回调记录, 回调配置独立页. Callback is per-campaign —
  it survives only as the campaign 回调 tab.
- *Fold away (rare-but-real)*: 通话监控, 转人工任务, 节假日, 设备在线状态, 音色目录. These keep their
  views and backends; only their entry point moves into the "更多/设置" area. 音色 additionally
  surfaces as a `voice_id` picker on campaign config.

**D3 — Fold-away mechanism reuses existing design language.** A "更多/设置" grouping in the user
menu (el-dropdown) or a gear 圆按钮 opening a drawer — no new component system. 通话监控 also gets
a context-local「实时监控」entry from 场景详情 / CallDetail (closer to user mental model).

**D4 — Redirect cleanup.** The existing `OPERATIONS_REDIRECTS` (old top-level → `/operations/*`)
is pruned: entries pointing at deleted paths are removed; survivors retargeted (e.g. `/dashboard`
becomes a real customer route again, so its redirect is dropped, not kept).

**D5 — Safe batch order** (each batch an independent, shippable commit):
1. *Additive, zero-delete*: 场景 卡片「删除场景」action; `/dashboard` pill; `voice_id` picker.
2. *Fold-away + migrate rare*: "更多/设置" area; move 监控/转人工/节假日/设备/音色 into it; consolidate
   callback into the campaign tab; fix the `callback-config-edit` dead route.
3. *Destructive deletes*: remove `CampaignList` / `OperationsIndex` / SIM / callback-logs /
   callback-configs-list + their routes + `OPERATIONS_REDIRECTS` cleanup + 运营管理 nav entry.
4. *Stale-terminology cleanup* (parallelizable, low-risk): 润色 banner copy, PipelineTrace
   single→N referee, PromptTier* rename, CampaignDetail「4-tier」block — the front-end tail of
   `engine-spec-terminology-purge`.

The「删除场景」affordance (batch 1) is a hard prerequisite for deleting `CampaignList` (batch 3).

**D6 — `CampaignEdit` stays reachable during the deferral.** Because the campaign-config内部 redesign
is engine-gated, `CampaignEdit` is NOT folded into `CampaignDetail` in this change. The
`operations-campaign-edit` route is retained (renamed off the `operations-` prefix, or kept) and
`CampaignDetail`'s「高级配置」button continues to reach it — this is the one intentional,
documented exception to "no operations zone", removed by the follow-up engine-gated change.

## Risks / Trade-offs

- **Deleting pages is irreversible** — mitigated by the batch order (deletes last, after additive
  batches ship) and by deleting only ground-truthed dead stubs; real-backend views are folded, not
  deleted. Each batch is a separate commit for clean rollback.
- **Dangling refs** — every inbound ref is enumerated and rewired in the same batch as its target's
  removal; `check:routes` + a manual no-404 sweep gate acceptance.
- **Deferred-campaign awkwardness (D6)**: keeping `CampaignEdit` reachable means the operations zone
  isn't 100% gone until the follow-up change. Accepted: forcing the campaign-config redesign now
  would contradict the engine freeze and the "不露 label/routing" rule. Documented as a known,
  time-boxed exception.
- **Spec drift on referee semantics**: the existing「已 spec 能力的 UI 暴露」requirement still
  describes referee output as `{decision, goal_type, confidence}` (pre-refactor). This change does
  NOT touch it (deferred to the engine-gated follow-up) to avoid half-correcting a moving target.
