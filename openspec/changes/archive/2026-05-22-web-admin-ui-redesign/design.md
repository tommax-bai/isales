## Context

`isales-web` was bootstrapped in Phase 7 (`archive/2026-05-08-impl-web`) as an Element Plus admin dashboard with a left sidebar + breadcrumb layout, one view per backend domain. Recent change `archive/2026-05-19-web-admin-deploy` shipped the SPA to ECS nginx at `http://121.89.85.150/`. The product user has since produced a Figma Make design (`fileKey: nerQwSnKLKJYWiGGb5NN3C`, React + Tailwind + shadcn/ui) that reorganizes the UI around a small-business outbound-call workflow: lead → call → appointment, with three secondary config entries (AI 外呼 / ASR-TTS 通路 / 模型厂商). The Figma file's 7 business components (`App`, `Appointments`, `CallRecords`, `LeadManagement`, `AICallConfig`, `ModelProviderConfig`, `VoiceChannelConfig`) and design tokens (`src/styles/theme.css`) have been pulled via Figma MCP and serve as visual + interaction reference.

Audit finding: most of what the Figma design "introduces" — multi-parallel prompts (`role-prompt`, `filler`, `goal-achievement`, `ai-pipeline`), ASR transcripts (`transcript`), goal-achievement scoring (`goal-achievement`), provider credentials (`provider-abc`), call-time windows (`time-window`) — already exists at spec + backend level. The current admin UI just doesn't expose them. The only genuine new capability is **Appointment** (no data model, no spec, no view).

Constraints:
- v1.0 GA is single bundled release ([[feedback_release_atomicity]]) — no incremental cutover gates.
- Stack stays Vue 3 + Element Plus + Pinia + Vite + axios. No React port.
- Cloud-side already runs nginx + SPA fallback ([[project_a2_qa_deploy]]); redeploy uses the same `web-admin-deploy` flow.
- Element Plus 2.8 supports SCSS variable override; CSS custom properties available at runtime for the design-token surface.
- No external integrations bookmark internal admin routes, so URL changes are acceptable with router-level redirects.

## Goals / Non-Goals

**Goals:**
- Replace the IA: top sticky pill-nav with 3 customer entries + 3 config buttons, sidebar removed.
- Add Appointment domain end-to-end: data model, API, view, and lead-status state coupling.
- Surface already-spec'd capabilities (multi-parallel prompts, ASR bubbles, goal scoring, provider creds, call-time windows) in dedicated views.
- Re-skin the redesigned views to Figma's visual language (oklch palette, 0.625rem radius, lucide icons) without forking Element Plus.
- Demote operational views (Dashboard / Campaigns / Monitor / Callbacks / Handoff / Holidays / Devices / SimCards) into `/operations/*` sub-area; preserve functionality.

**Non-Goals:**
- Porting to React / Tailwind / shadcn-ui. The Figma TSX is reference only.
- Building a fresh component library or replacing Element Plus primitives. We override theme, not components.
- Dark-mode UX. Tokens reserve `.dark` variables but no toggle UI; defer to a later change.
- Rewriting the operational views' internals. We move their entry point; we don't touch their logic.
- Multi-tenant / SaaS layer (separate change in v1 roadmap).
- Mobile-first redesign. Top-nav collapses gracefully on mobile but the views remain desktop-optimized.

## Decisions

### D1: Keep Vue 3 + Element Plus; theme-override + design-tokens.css, no component rewrite

**Choice**: Element Plus 2.8 + a new `src/styles/design-tokens.css` that exposes Figma tokens as CSS custom properties, plus an SCSS file (`src/styles/element-plus-theme.scss`) that maps EP's SCSS variables (`$colors`, `$border-radius`, etc.) to the token surface at build time.

**Alternatives considered**:
- **Port to React + shadcn/ui** (1:1 Figma replication): Rejected. Sunk cost: 11 existing Vue views + auth flow + router + axios layer + WS client. ~4–6 weeks rewrite vs ~2 weeks theme. No business value differentiator from changing framework.
- **Fork Element Plus components**: Rejected. Maintenance debt; upstream upgrades become painful. Theme override covers ~90% of visual needs.
- **Use UnoCSS / Tailwind side-by-side**: Rejected for this change. Adds a second styling paradigm. Token-driven CSS variables suffice for current scope.

**Why**: Smallest blast radius. Existing views continue to render; redesigned views inherit the same EP primitives with restyled chrome. Tokens are the single source of truth.

### D2: Top-nav segmented control via custom Vue component (not `el-menu` / `el-tabs`)

**Choice**: Hand-rolled `<TopNav>` component using a flex layout, two pill containers, and `lucide-vue-next` icons. Renders three text+icon buttons in the center container and three circular icon buttons in the right container. `vue-router` controls active state via `route.name` matching.

**Alternatives considered**:
- `el-menu` horizontal mode: Visual mismatch with Figma's pill-on-pill layout; difficult to nest two separate pill containers cleanly.
- `el-tabs`: Pages aren't tabs — they're routes. Forcing tab semantics costs accessibility (announces "tab" not "link").

**Why**: ~80 lines of Vue component vs fighting EP styles. Direct control over states (active / hover / disabled / mobile-collapsed).

### D3: Operational views demoted to `/operations/*` with 301-equivalent client redirects

**Choice**: `vue-router` `beforeEach` guard maps the 9 demoted top-level paths to their `/operations/<old-path>` equivalent. Sub-area entry point lives in the top-nav overflow menu (and as a fallback `/operations` index page that lists them).

**Alternatives considered**:
- **Delete the demoted views**: Rejected. Operational features (campaign/device/handoff/callbacks) are needed for running the platform. Just not by customer-facing personas.
- **Two separate layouts** (`CustomerLayout` + `OperationsLayout`): Considered. Cleaner separation but doubles boilerplate. Single `AppLayout` with conditional sub-area rendering is simpler for v1.
- **Server-side 301**: Rejected. SPA only — nginx already serves `index.html` for everything; routing is client-side.

**Why**: No bookmark breakage, zero feature loss, minimal IA pollution on customer-facing views.

### D4: Appointment status mutation via `PATCH /api/appointments/{id}/status` with `action` verb

**Choice**: Status changes go through a dedicated endpoint with `{ "action": "confirm" | "complete" | "cancel" }`. Server validates the source→target transition; rejects illegal transitions with HTTP 409. Lead-status side-effects (`appointed` on create, `visited` on complete) happen in the same DB transaction.

**Alternatives considered**:
- `PATCH /api/appointments/{id}` accepting `status` field directly: Rejected. Lets a buggy client write `cancelled → confirmed` and corrupt state. Action-verb encodes intent and centralizes validation.
- Separate endpoints (`POST .../confirm`, `POST .../complete`, `POST .../cancel`): Rejected. Triples surface area for the same state-machine logic. One endpoint + action enum balances simplicity and intent capture.

**Why**: Same pattern as the `call-state-machine` spec — state transitions are first-class operations, not field writes. Encourages idempotent retries (sending `confirm` on an already-confirmed appointment is a 409, never a silent overwrite).

### D5: Appointment owned by `api` service, model in `isales-common`

**Choice**: Appointment is a customer-workflow artifact created and managed by the admin (`isales-api`), not produced by engine/telephony/worker. Owns the table per [[data-model]] § "表归属与全表清�" convention. Alembic migration lives in `isales-common`.

**Alternatives considered**: `worker` (since it could be auto-created from call summary): Rejected. Auto-creation isn't in this change's scope; appointments are explicitly user-driven from the call-records view. If we later auto-suggest from summary, the producer is still worker but the owner stays api.

### D6: ASR bubble rendering — parse `call_record.transcript` JSONB, fall back to plain notes

**Choice**: Reuse the existing `transcript` JSONB. The `transcript` spec defines the schema; we read its turn entries (AI/customer alternating, with `role` + `text` per turn) to render bubble pairs. If `transcript` is empty but `notes` exists, fall back to the legacy plain-text notes panel.

**Open question**: confirmed turn schema needs an engine read pass before view implementation (see Open Questions §1).

### D7: Multi-parallel prompt UI maps to existing `role_config` + `prompt_version` tables

**Choice**: The AI 外呼配置 view's 4 tiers (conversation / filler / quality / polish) map to existing `role_config.kind` values. N configs per tier = N rows in `role_config` with the same `kind`. Each row has its own `enabled` flag and links to a `prompt_version`. The view CRUDs these rows via existing admin endpoints (or new endpoints if any tier isn't yet HTTP-exposed; verified during apply).

**Why**: Spec already supports N configs ([[role-prompt]], [[ai-pipeline]]). Backend doesn't change. UI is the missing layer.

### D8: Design tokens as CSS custom properties on `:root`, not Sass variables

**Choice**: `src/styles/design-tokens.css` declares variables on `:root` (and `.dark` for future toggle). All redesigned-view components reference them via `var(--isales-…)`. Element Plus's Sass theme override is a separate, smaller file that maps a handful of EP variables (`--el-color-primary`, `--el-border-radius-base`) to our tokens at build time.

**Alternatives considered**:
- Pure Sass override: Rejected for runtime themability and for keeping tokens introspectable in devtools.
- Tailwind + theme config: Rejected (see D1).

## Risks / Trade-offs

- **[Risk] Element Plus theme override doesn't cover every component's internals** (some EP components use hard-coded greys / shadows). → **Mitigation**: redesigned views minimize deep EP usage in favor of token-driven custom shells; use EP primitives (Button / Input / Select / Switch / Slider / Dialog) but wrap them in cards/headers we control. Audit at apply time; file targeted SCSS overrides for any EP component that leaks default styling.

- **[Risk] `transcript` JSONB schema may not match the Figma assumption of strict alternating AI/customer turns**. → **Mitigation**: design the bubble component to consume an explicit `{role, text}[]` array from a thin frontend adapter. Adapter accepts whatever shape `transcript` actually has (verified via engine code read in T1.4) and normalizes. If real schema lacks role tags, fall back to time-ordered plain rendering and treat as a follow-up spec change.

- **[Risk] Bookmark breakage for internal admin users** (operational routes move). → **Mitigation**: router redirects (D3) preserve old URLs; release note in `STATE.md` and operational team Slack ping.

- **[Risk] Alembic migration runs on populated cloud DB**. → **Mitigation**: appointment is a new table — additive only, zero migration risk. No `lead.status` enum change in this proposal (the new enum values `appointed` / `visited` are already valid string values in the existing `lead.status` text column; we verify column type during T2.1).

- **[Risk] `lucide-vue-next` bundle size**. → **Mitigation**: tree-shaken named imports per Vite default; total icon weight measured during T1.5 — expected < 30 KB gzipped for the ~30 icons we use.

- **[Trade-off] Customer-facing IA loses one-click access to operational views**. → Acceptable per product direction; operational personas (platform admin) acquire one extra click through the overflow menu or `/operations` index.

- **[Trade-off] Designing without dark mode now means tokens are duplicated (light + dark) without test coverage on dark**. → Acceptable; dark variables are placeholders, no UI toggle.

## Migration Plan

1. **Spec + scaffold** (T1): land design tokens, theme override, top-nav component, router rewrite, operational `/operations/*` redirects. No backend change. Old views still render under new paths.
2. **Backend additions** (T2): alembic migration for `appointment` + Pydantic schema + SQLAlchemy model in `isales-common`; FastAPI router + endpoints in `isales-api`; pytest coverage.
3. **Redesign existing views** (T3): rebuild `LeadList.vue` + `CallList.vue` to Figma layout, leveraging existing API + transcript adapter.
4. **Build new views** (T4): `AppointmentList.vue` + 3 config views.
5. **Cloud deploy** (T5): rebuild `dist/`, rsync to `/var/www/isales-web/`, run `alembic upgrade head` on ECS, smoke-test login + each new view + appointment CRUD; update `deploy/cloud/STATE.md`.
6. **Cleanup** (T6): remove dead sidebar code, ensure `make test-all` green.

**Rollback**:
- Frontend regression: `git revert` the merge commit, `npm run build`, redeploy previous `dist/` via the same web-admin-deploy flow. No DB change needed since appointment table is additive.
- Backend regression: `alembic downgrade -1` (drops `appointment` table — safe if no data) + redeploy previous `isales-api` release.

## Open Questions

1. **`transcript` JSONB schema** — **RESOLVED (T1.4 audit, 2026-05-19)**. `isales_common/schemas/jsonb/transcript.py` defines a discriminated union of 13 event types, all sharing `type` (discriminator) and `ts` (int, ms relative to call start). AI-bubble candidates (with `text`): `greeting | ai_reply | filler | default_reply_used`. Customer-bubble candidate (with `text`): `user_speech`. Remaining types (`interruption / silence_activation / transfer_initiated / transfer_marked / goal_achieved / wrap_up_started / wrap_up_completed / hangup`) are control events; `useTranscriptAdapter` (T4.2) MUST filter them out of the bubble stream.
2. **Existing admin API coverage for `role_config` / `filler_set` / `voice_model` / `time_windows`** — **RESOLVED (T1.5 audit, 2026-05-19)**. Audit of `isales-api/isales_api/routers/`:
   - ✅ `voice_models.py` — full CRUD (`voice-models` view stays operational)
   - ✅ `campaigns.py` — `campaign.time_windows` accessible via `PATCH /campaigns/{id}` nested write (no separate endpoint needed)
   - ✅ `holidays.py`, `leads.py`, `calls.py` — full CRUD
   - ❌ `role_config` — NO standalone CRUD endpoint (only readable through `campaign.role_configs` nested response)
   - ❌ `prompt_version` — NO endpoint
   - ❌ `filler_set` / `filler_phrase` — NO endpoint
   - ❌ provider-credentials — NEITHER endpoint NOR model exists (no `provider_credential` table); current convention reads API keys from env files
   
   **Resolution for §3.8**: introduce minimal CRUD endpoints for `role_config` + `prompt_version` + `filler_set` + `filler_phrase` (these tables already exist; only HTTP surface is missing). Provider-credentials remains out-of-scope for this change — `ModelProviderConfig.vue` (T5.7) reads/writes a frontend-only stash (localStorage), with a "Backend storage pending" banner. Schema work for `provider_credential` becomes a separate change in v1 roadmap.
3. **Will operational views eventually move to their own SaaS-admin layout** ([[project_v1_blueprint]] multi-tenant plan)? Out of scope here; the `/operations/*` namespace anticipates a future split with zero rework.
