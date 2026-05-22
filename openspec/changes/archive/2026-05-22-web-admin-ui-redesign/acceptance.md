# Acceptance — web-admin-ui-redesign

**Verified (local):** 2026-05-19, on the current dev rig (Apple Silicon mac).
**Verified (cloud):** PENDING — see "Deferred" below.

## What this change shipped

Replaces the sidebar-shaped admin UI with a **customer-outbound-workflow**
top-nav IA: three primary entries (`线索 / 外呼 / 预约`) + three circular
config buttons (AI 外呼 / ASR-TTS 通路 / 模型厂商). Demotes 10 platform-ops
views (Dashboard / Campaigns + edit / Monitor / Callback configs+logs /
Handoff / Holidays / Devices / SIM cards / Voice models) under
`/operations/*`, with client-side permanent redirects from the old
top-level paths.

End-to-end new domain: **Appointment**. New SQLAlchemy model + alembic
migration in `isales-common` (`appointment` table, FKs to `lead`
CASCADE + `call_record` SET NULL); new FastAPI router in `isales-api`
with 6 endpoints including a state-machine
`PATCH /appointments/{id}/status` that takes a `confirm | complete |
cancel` action verb (rejects illegal transitions with 409). Lead-status
side-effects (`appointed` on create, `visited` on complete; `cancel`
does not touch the lead) run in the same DB transaction. 14 pytest
tests cover the full matrix.

Exposes already-spec'd backend capabilities in dedicated customer-side
views: ASR transcript bubbles (parses the discriminated-union JSONB into
AI-left + customer-right bubbles), goal-achievement panel (score /
intent / appointment-booked / key-points read from
`call_summary.extracted_fields`), 4-tier parallel prompt config
(dialog / judge / polish / filler), ASR/TTS/voice channel config,
and per-provider API-key card with masked preview.

Stack stays Vue 3 + Element Plus + Pinia + Vite. New: `lucide-vue-next`
icon library and `src/styles/design-tokens.css` (oklch palette + 0.625rem
radius + status colors with bg/border/text tiers + bubble colors) +
`src/styles/element-plus-theme.scss` (EP `$colors`/`$border-radius`/
`$font-size` mapped to design tokens). Vite injects the theme SCSS via
`css.preprocessorOptions.scss.additionalData`.

## Code path

- `isales-common 0.3.0`:
  - `models/appointment.py` — `Appointment` ORM model with relationships.
  - `schemas/appointment.py` — `AppointmentCreate / Update / Read /
    StatusAction` DTOs.
  - `enums.py` — `LeadStatus.APPOINTED / VISITED / LOST` + new
    `AppointmentStatus` / `AppointmentAction` StrEnums.
  - `alembic/versions/a1b2c3d4e5f6_add_appointment_table.py` — additive
    migration (CREATE TABLE + 4 indexes + 2 FKs).
- `isales-api` (no version bump — pin updated to `>=0.3.0,<0.4`):
  - `routers/appointments.py` — 6 endpoints; `_next_status()`
    state-machine; lead-status side-effects in same transaction.
  - `main.py` — wires the new router.
  - `tests/test_appointments.py` — 14 tests; conftest TRUNCATE list now
    includes `appointment`.
- `isales-web`:
  - `components/TopNav.vue` (new) + `Layout/DefaultLayout.vue` (rewritten)
    — sticky top header replaces sidebar.
  - `components/Common/{StatusBadge,PageHeader}.vue` — shared chrome.
  - `components/Calls/{TranscriptBubbles,GoalAchievementPanel,
    CreateAppointmentDialog}.vue` — call-record enrichment.
  - `components/Appointment/AppointmentCard.vue` — pending/confirmed/
    terminal action variants.
  - `components/Config/PromptConfigList.vue` — reused 4× by AICallConfig
    tiers.
  - `composables/{useTranscriptAdapter,useStatusMeta,
    useLocalConfigStash}.ts` — transcript normalization, status →
    color/label, localStorage-backed config stash.
  - 6 customer-side views: `Leads/LeadList.vue` (rewritten),
    `Calls/{CallList,CallDetail}.vue` (rewritten/enriched),
    `Appointments/AppointmentList.vue` (new), `Config/{AICallConfig,
    VoiceChannelConfig,ModelProviderConfig}.vue` (new).
  - `Operations/OperationsIndex.vue` (new) — index card grid for the 10
    demoted ops views.
  - `router/index.ts` — full rewrite; `OPERATIONS_REDIRECTS` table +
    `/monitor/:id` special-case in `beforeEach`; `/` redirects to
    `/leads` for customer-first landing.
  - `styles/{design-tokens.css,element-plus-theme.scss}` — visual base.
  - `package.json` — `lucide-vue-next` + `sass` added.
  - `vite.config.ts` — SCSS preprocessor injection + EP resolver
    `importStyle: "sass"`.

## Verified — local

| Surface | Check | Result |
|---|---|---|
| openspec | `openspec validate web-admin-ui-redesign --strict` | ✅ valid |
| openspec totals | `make spec-validate` (19 specs + 5 changes) | ✅ all pass |
| isales-common pytest | 129 / 129 (test_enums extended for new lead statuses) | ✅ |
| isales-api pytest — appointments | 14 / 14 (CRUD × 6 + state-machine × 7 + auth × 1) | ✅ |
| isales-api pytest — overall | 78 / 81 (3 pre-existing redis/JWT flakes unrelated to this change) | ⚠ pre-existing |
| isales-engine pytest | 265 / 265 | ✅ |
| isales-telephony pytest | 360 / 360 | ✅ |
| isales-worker pytest | 45 / 45 | ✅ |
| isales-scheduler pytest | 36 / 39 (3 pre-existing redis flakes unrelated) | ⚠ pre-existing |
| isales-web vitest | 39 / 39 | ✅ |
| isales-web vite build | `vue-tsc --noEmit && vite build` | ✅ built in ~5s; biggest customer-side chunk LeadList 14.4kB / AICallConfig 9.2kB; lucide tree-shake effective |

## Spec deltas

- New capability `web-admin-ui` — top-nav IA, customer-view inventory,
  ops-view demotion, exposed backend capabilities (parallel prompts /
  ASR bubbles / goal scoring / provider creds / time windows), design
  token vocab, lucide icon convention.
- New capability `appointment` — data model, status state machine, lead
  status coupling, admin API surface, view layout rules.
- `data-model` MODIFIED — `appointment` row added to the canonical table
  inventory.

## IA before / after

Before (sidebar):

    Dashboard / Campaigns / Leads / Devices+Voice / Calls / Callbacks /
    Handoff / Holidays …

After (top-nav):

    [线索｜外呼｜预约]    ⚙️ AI外呼   🌊 ASR-TTS   🔑 模型厂商
                                                       User menu → 运营管理 → /operations

## Deferred — explicit follow-up

1. **Cloud-side deploy (§6.3–§6.7)** — requires SSH to ECS
   `121.89.85.150`. Sequence is documented in tasks.md:
   1. Backup `/var/www/isales-web/` → `/var/www/isales-web.bak-<date>/`
   2. `alembic upgrade head` in isales-api venv (creates `appointment` table)
   3. `systemctl restart isales-api` + grep startup logs for errors
   4. `rsync dist/ → /var/www/isales-web/` (nginx static, no reload)
   5. Browser smoke: login → 6 entries reachable; leads → call →
      create-appointment → appointments flow; transcript bubbles render
      against real data; `/dashboard` redirects to `/operations/dashboard`.
   6. Update `deploy/cloud/STATE.md` (new alembic head + nginx version
      bump + smoke evidence) and `MEMORY.md` entry.
2. **`role_config` / `prompt_version` / `filler_set` / `filler_phrase`
   HTTP CRUD endpoints** — current backend has no such endpoints; tables
   already exist. AICallConfig view stashes to localStorage and shows a
   "backend pending" banner; swap-in is a wholly additive isales-api
   change with no UI churn (see `useLocalConfigStash` →
   `apiClient.get/post/patch` migration path).
3. **`provider_credential` table + endpoints** — neither model nor HTTP
   surface exists; production API keys still come from env files.
   ModelProviderConfig view shows a warning banner stating "Backend
   storage pending; key remains in localStorage".
4. **Dark-mode UI toggle** — design-tokens.css declares `.dark` variables
   but no toggle ships. Out of scope per design.md non-goal.

## Risks observed during implementation

- **Pydantic `extra="forbid"` makes status leak attempts fail 422** —
  matched the spec intent (clients MUST go through `PATCH .../status`),
  but the test was originally written to expect a silent ignore; updated
  it to assert 422 + status unchanged. (test_appointments.py
  `test_status_cannot_be_set_directly`.)
- **`obj.status` after SQLAlchemy refresh comes back as a plain `str`**
  not the `AppointmentStatus` StrEnum — `_next_status()` and the field
  PATCH endpoint coerce via `AppointmentStatus(current)` to keep the
  state-machine type-clean. Same pattern applies anywhere we
  enum-compare a freshly-refreshed status column.
- **isales-common v0.3.0 cascade** — all 4 consumer service pyprojects
  bumped from `>=0.2.0,<0.3` to `>=0.3.0,<0.4`; venvs reinstalled with
  `pip install -e ../isales-common`. CI image rebuilds will need to
  pick this up too (out-of-scope here; documented for the deploy step).
