## Why

The current `isales-web` admin UI (11 views built incrementally over Phase 7 + the recent `web-admin-deploy` archive) is shaped by **service architecture** (one view per backend domain: campaigns, devices, sim-cards, callbacks, handoff-tasks, holidays …) rather than by **customer outbound-call workflow**. The Figma Make design (`fileKey: nerQwSnKLKJYWiGGb5NN3C`) reorganizes the same backend capabilities around the three things a small-business sales user actually does: capture **leads → make AI calls → book in-store appointments**. It also surfaces several already-spec'd capabilities that the current UI keeps invisible (ASR transcripts, goal-achievement scoring, multi-parallel prompt strategies, ASR/TTS/model-provider credentials, call-time windows).

Doing this redesign now — before v1.0 GA — lets us land a UI that matches how customers will be onboarded, without later breaking saved-state or muscle-memory.

## What Changes

- **NEW top-level information architecture**: replace the sidebar `DefaultLayout` with a sticky pill-segmented top nav: `[线索 | 外呼 | 预约]` as the three primary entries + three circular config buttons `[⚙️ AI 外呼配置, 🌊 ASR/TTS 通路, 🔑 模型厂商]`. **BREAKING** for any deep links into sidebar routes that get re-homed.
- **NEW Appointment domain**: data model (`Appointment` table + relations to `Lead` and `CallRecord`), API endpoints (CRUD + status transitions: `pending → confirmed → completed | cancelled`), and `appointments` view (即将到店 / 历史 grouping, 确认/完成/取消 actions, store-address + directions fields). **NEW capability** — neither spec, data-model, nor any view covers this today.
- **EXPOSE existing-spec capabilities currently hidden in UI**:
  - **AI call config view**: 4-tier parallel prompt management (对话策略 / 垫词 / 质量判别 / 润色), N configs per tier, each with own provider/model/temperature/topP. Backend already supports this (`role-prompt`, `filler`, `goal-achievement`, `ai-pipeline` specs); UI just needs to add the editor.
  - **ASR/TTS channel config view**: enable/disable/edit ASR + TTS + voice library entries; pick the active channel per call. Backend covered by `provider-abc`.
  - **Model provider config view**: per-provider API key + endpoint + (OpenAI-only) org-id management with masked input + reveal toggle.
  - **Call-time-window editor**: multi-range time-window picker (already speced in `time-window`).
  - **Call detail enrichment**: ASR conversation bubbles (AI 左 / 客户 右), goal-achievement score panel (score / interest / appointmentBooked / keyPointsCovered) — `transcript` and `goal-achievement` specs already produce these fields.
- **DEMOTE operational-platform views** into a secondary "运营" sub-area (二级菜单 inside top-nav overflow): Dashboard, Campaigns + Campaign-Edit, Monitor, Callback-Configs + Callback-Logs, HandoffTasks, Holidays, Devices, SimCards. They stay functionally intact — only the IA placement changes.
- **NEW design tokens & component conventions**: introduce `src/styles/design-tokens.css` with the Figma `oklch` palette (`--primary: #030213`, `--radius: 0.625rem`, status-badge color set) + Element Plus SCSS theme override file. Replace `@element-plus/icons-vue` with `lucide-vue-next` for icons in redesigned views (legacy demoted views may keep Element Plus icons).
- **KEEP technology stack**: Vue 3 + Element Plus + Pinia + Vite + axios + vue-router. No port to React/shadcn. The Figma TSX source serves as visual + interaction reference, not code import.

## Capabilities

### New Capabilities

- `web-admin-ui`: Defines the admin frontend's information architecture, navigation structure, view inventory, design tokens / theme, icon library convention, and the route map. Captures the "what the admin frontend looks like and how it's organized" contract that today exists only implicitly inside the `isales-web` codebase.
- `appointment`: Defines the in-store appointment domain — data model, lifecycle (`pending → confirmed → completed | cancelled`), relations to `Lead` (status transition `appointed → visited`) and `CallRecord` (an appointment is typically created from an interested call), and the admin endpoints for managing them.

### Modified Capabilities

- `data-model`: Add `appointments` table + the `Lead.status` enum value extensions (`appointed`, `visited`) if not already present, plus the FK from `Appointment.lead_id → Lead.id` and the optional FK from `Appointment.created_from_call_id → CallRecord.id`.

## Impact

- **Affected repos**:
  - `isales-web` (heavy): new top-nav layout, 6 redesigned/new views, 5 demoted views moved under `/operations/*` sub-area, Element Plus theme override, design-tokens.css, lucide icon migration, router restructure.
  - `isales-common` (medium): new `Appointment` SQLAlchemy model + Pydantic schema; new alembic migration; possibly `Lead.status` enum extension.
  - `isales-api` (medium): `GET/POST/PATCH /api/appointments`, `PATCH /api/appointments/:id/status`, plus admin endpoints exposing existing `provider-abc` / `role-prompt` / `filler` / `time-window` config CRUD if any are not yet HTTP-exposed.
  - `deploy/cloud/` (light): re-deploy `isales-web/dist/` via the existing `web-admin-deploy` flow + DB migration step on ECS. Update `STATE.md`.
- **Affected specs**: new `web-admin-ui/spec.md`, new `appointment/spec.md`, delta on `data-model/spec.md`.
- **No change to**: realtime call engine, edge client, telephony, scheduler, worker, gRPC contracts, RTC plane.
- **Breaking**: deep links to demoted sidebar routes (`/campaigns`, `/devices`, `/sim-cards`, `/holidays`, `/callback-configs`, `/callback-logs`, `/handoff-tasks`, `/monitor/:id`, `/dashboard`) will move under `/operations/*`. Acceptable because no external integrations bookmark these — only internal admins.
- **Dependencies on active changes**: none blocking. `cloud-edge-grpc-keepalive` and `windows-artc-pybind11` operate below the UI layer; both can land in either order.
