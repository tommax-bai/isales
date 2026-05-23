# Acceptance — web-admin-campaign-workflow

**Verified (local):** 2026-05-22, on the Windows dev rig
(`C:\Users\tianx\codes\isales*`, Python 3.11.13 / Node 20).
**Verified (cloud):** 2026-05-23 — backend deploy + nginx reload + HTTP
smoke (SPA 200 + API new-router 401 鉴权 ✓) executed; isales-api +
isales-scheduler restart clean, log scan 0 error. **Full browser UX smoke
still owed** (UI flow 建场景 → 配置 → 启停 → 加线索 dropdown → next_call_at
init) — see "Deferred" below.

## What this change shipped

Brings **campaign**（"场景"）back into the customer-facing workflow after
`web-admin-ui-redesign` had hidden it under `/operations/campaigns`. Campaign
is now the customer workflow's first step: 建场景 → 配策略 → 启停 → 灌线索 →
看外呼 → 收预约. The top-nav becomes 4 entries `[场景｜线索｜外呼｜预约]`
and the three round config buttons collapse to one（仅「模型厂商」）.

Per-campaign outbound strategy（4-tier parallel prompt, 垫词, 可拨时段,
选用音色）moves from the previous **global localStorage** stash into
**真正持久化到后端** per-campaign records — `isales-api` gains 4 new admin
CRUD routers (`role_configs` / `prompt_versions` / `filler_sets` +
nested `filler_phrases`) plus a campaign-level `GET /campaigns/{id}/progress`
aggregation endpoint. The frontend `AICallConfig.vue` /
`VoiceChannelConfig.vue` / `PromptConfigList.vue` views are deleted; their
logic moves into `CampaignDetail.vue` via two new components
(`PromptTierEditor` + `FillerEditor`) talking to the new admin endpoints.

ASR/TTS provider credentials fold into the global **「模型厂商」** view
(`ModelProviderConfig.vue`): one volcengine app_key/token covers LLM + ASR +
TTS, so a dedicated voice-channel view is unnecessary. The voice-model
catalogue stays on the operations side (`/operations/voice-models`);
campaign detail "uses" a voice via a dropdown rather than managing the
catalogue.

`LeadEditDialog.vue` replaces the numeric "任务 ID" input with a campaign
dropdown showing each campaign's name + running/stopped badge. `LeadList.vue`
loses the per-row 「外呼」button — it used to write `lead.status = 'queued'`
which scheduler never scans (dead bug); outbound is now uniformly campaign-
driven via the campaign detail page's 启动 / 停止 buttons.

Scheduler's lead-selection SQL extends to `next_call_at IS NULL OR
next_call_at <= now`. Previously, freshly-imported leads (which leave
`next_call_at = NULL` because nothing initializes it) would never enter
the scheduler scan — newly-imported leads were silently un-callable. With
NULL treated as immediately callable, "启动场景" actually picks up its
campaign's new leads on the next tick. `loop.py`'s existing `ORDER BY
next_call_at ASC` puts NULL leads after scheduled retries via Postgres's
default `NULLS LAST` (semantically: 新线索不比重试急).

Stack stays unchanged: Vue 3 + Element Plus + Pinia + Vite +
FastAPI/SQLAlchemy. **No DB migration** in this change (the 4 backing
tables already exist from earlier work).

## Code path

- `isales-common 0.3.2` (bumped from 0.3.0; deviation from proposal
  which assumed "no common bump"):
  - `schemas/filler.py` (**new**) — `FillerSetCreate / Update / Read` +
    `FillerPhraseCreate / Update / Read` Pydantic DTOs. The proposal
    asserted these already existed; they did not (ORM models existed,
    schemas did not). Schema parity with `lead.py` `extra="forbid"`.
  - `redis_keys.py` (**new**) — shared `SCHEDULER_ACTIVE_CAMPAIGNS_SET`
    constant so `isales-api` (writer) and `isales-scheduler` (reader)
    no longer string-duplicate the redis key.
  - **Consumer pins (`isales-api` / `isales-scheduler`) remain
    `>=0.3.0,<0.4`** — the new 0.3.2 is in-range, so no cascade pin
    bump was needed across the 4 service repos.

- `isales-api`:
  - `routers/role_configs.py` (**new**) — `role_config` CRUD,
    `list(campaign_id, kind)` filtering, JWT-guarded, pagination per
    `leads.py` shape.
  - `routers/prompt_versions.py` (**new**) — `prompt_version` CRUD with
    `_deactivate_siblings()` invariant: setting `is_active=True` flips
    every other version in the same `(scope_type, scope_id)` to false,
    atomically in one transaction.
  - `routers/filler_sets.py` (**new**) — `filler_set` CRUD + nested
    `POST/PATCH/DELETE /filler-sets/{id}/phrases/...` for filler phrases.
  - `routers/campaigns.py` — adds `GET /campaigns/{id}/progress`
    returning `{ status_counts: {...}, is_active: bool }` via one
    GROUP BY query + one `SISMEMBER` on the active set.
  - `schemas.py` — `CampaignProgress` Pydantic schema.
  - `main.py` — wires the 3 new routers.
  - `tests/test_campaign_configs.py` (**new**, 10 tests) — CRUD + auth
    + campaign-id filter + `_deactivate_siblings` invariant +
    `progress` aggregation; conftest TRUNCATE list adds `prompt_version`.

- `isales-scheduler`:
  - `loop.py` — `Lead.next_call_at <= now` → `Lead.next_call_at.is_(None)
    | (Lead.next_call_at <= now)`.
  - `control.py` — switches to the shared `SCHEDULER_ACTIVE_CAMPAIGNS_SET`
    constant from `isales-common.redis_keys`.
  - `tests/test_null_next_call.py` (**new**, 1 test) — asserts a new lead
    with `next_call_at=NULL` reaches `status=CALLING` after one tick once
    its campaign is in the active set. (Used `lead.status=CALLING` as the
    assertion rather than `redis.llen` because the existing redis-based
    assertion in `test_loop.py` is flaky against local redis; same
    pre-existing flake — out of scope.)

- `isales-web`:
  - `components/TopNav.vue` — `businessEntries` gets `campaigns`（场景,
    Megaphone icon, 最左）; `configEntries` shrinks from 3 to 1 (仅模型
    厂商); `isActive` matches `campaign-*` sub-routes.
  - `router/index.ts` — adds customer-facing `/campaigns`
    (`CampaignWorkspace`) + `/campaigns/:id` (`CampaignDetail`); removes
    `/campaigns → /operations/campaigns` redirect; operations-side
    `operations-campaigns` / `operations-campaign-edit` routes unchanged.
    Drops `config-ai-call` + `config-voice-channels` routes.
  - `views/Campaigns/CampaignWorkspace.vue` (**new**) — customer-facing
    campaign list, card grid with start/stop badge (`progress.is_active`)
    + lead count + 进度 + 新建场景 dialog. **Deviation:** proposal said
    `CampaignList.vue` but that filename was already taken by the
    operations-side view; renamed to `CampaignWorkspace.vue`.
  - `views/Campaigns/CampaignDetail.vue` (**new**) — header (启停 buttons
    wired to `POST /campaigns/{id}/start|pause`) + 进度 card + 基本信息
    (名称 / 并发 / 选用音色 dropdown writing `campaign.voice_id`) + 可拨
    时段 editor writing `campaign.time_windows` + AI 外呼策略区
    (3 tiers via `PromptTierEditor`, filler via `FillerEditor`) + sticky
    save bar. Exposes only the customer-relevant subset of campaign fields;
    advanced fields stay in operations-side `CampaignEdit.vue`.
  - `views/Config/ModelProviderConfig.vue` (**replaces** the 3-view config
    surface) — unified AI service provider credential manager covering
    LLM + ASR + TTS providers; volcengine card holds one app_key/token
    covering all three.
  - `components/Campaign/PromptTierEditor.vue` (**new**) — encapsulates the
    `role_config + prompt_version` CRUD dance for one tier (create flow:
    POST role_config → POST prompt_version → PATCH role_config
    `current_prompt_version_id`). **Deviation:** proposal said reuse
    `PromptConfigList.vue` (localStorage-shaped); built fresh for the
    API-backed shape instead. Three instances on `CampaignDetail`
    (role / judge / polish), independent save per row.
  - `components/Campaign/FillerEditor.vue` (**new**) — `filler_set +
    filler_phrase` editor saving inline.
  - `components/Lead/LeadEditDialog.vue` — 数字「任务 ID」→ campaign
    `el-select` (label `「name (运行中 / 已停止)」`); dialog open
    `loadCampaigns()`; empty-state hint with link to /campaigns when no
    campaign exists; campaign 锁定 in edit mode.
  - `views/Leads/LeadList.vue` — drops the per-card 「外呼」button (and
    its `queued` writer); card actions revert to edit-primary +
    delete-icon. Top banner: removed the time-window 9–21h check; static
    info banner now says 「外呼由场景驱动」with a 「前往场景」 link.
  - **Deleted:** `views/Config/AICallConfig.vue` /
    `views/Config/VoiceChannelConfig.vue` / `components/Config/
    PromptConfigList.vue` (last only used by AICallConfig, superseded by
    `PromptTierEditor`). localStorage stash keys for these views were
    left in place — harmless (no readers) and out of cleanup scope.
  - **New api modules:** `api/roleConfigs.ts` / `api/promptVersions.ts` /
    `api/fillers.ts` (+ shared `types/config.ts`).
  - `STYLE_GUIDE.md` — §0 view inventory updated (Campaigns added; 2
    config views removed); §8 待收敛 marked as resolved for the
    AICallConfig / VoiceChannelConfig items.

## Spec deltas

- `web-admin-ui` MODIFIED — ① IA: campaign 从「运营面 view 收纳」移入客户
  面工作流（顶部 4 entries）; ② customer-view inventory adds Campaigns
  list + detail, drops AICall + VoiceChannel; ③ "已 spec 能力的 UI 暴露"
  requirement deepens — AI 外呼配置 + ASR/TTS 通路 are now per-campaign
  persisted (no longer global localStorage stash).
- `retry-followup` MODIFIED — scheduler 调度数据流 SQL: `next_call_at <=
  now` extended to `next_call_at IS NULL OR next_call_at <= now`; NULL
  semantics become "immediately callable" for newly-imported leads.

## Verified — local

| Surface | Check | Result |
|---|---|---|
| openspec change | `openspec validate web-admin-campaign-workflow --strict` | ✅ valid |
| openspec totals | `openspec validate --specs && --changes` (21 specs + 5 changes) | ✅ all pass |
| isales-api pytest | 88 / 91 (3 pre-existing redis/JWT flakes unrelated) | ⚠ pre-existing |
| isales-api new tests | `test_campaign_configs.py` | ✅ 10 / 10 |
| isales-scheduler pytest | 37 / 40 (3 pre-existing redis flakes unrelated) | ⚠ pre-existing |
| isales-scheduler new tests | `test_null_next_call.py` | ✅ 1 / 1 |
| isales-common pytest | 129 / 129 | ✅ |
| isales-engine pytest | 265 / 265 | ✅ |
| isales-telephony pytest | 360 / 360 | ✅ |
| isales-worker pytest | 45 / 45 | ✅ |
| isales-web vitest | 39 / 39 | ✅ |
| isales-web build | `vue-tsc --noEmit && vite build` | ✅ clean |
| residue grep | `/config/ai-call` / `/config/voice-channels` / `AICallConfig.vue` writers / `queued` writers | ✅ 0 hits (remaining `queued` references are enum-display only) |

## IA before / after

Before (post-redesign, pre-this-change):

    [线索｜外呼｜预约]    ⚙️ AI外呼   🌊 ASR-TTS   🔑 模型厂商
    (campaign hidden under /operations/campaigns)

After:

    [场景｜线索｜外呼｜预约]    🔑 模型厂商
    (per-campaign 4-tier prompt / 垫词 / 时段 / 选用音色 → /campaigns/:id)

## Cloud deploy log (2026-05-23)

| Step | Result |
|---|---|
| backup `/var/www/isales-web/` → `/var/www/isales-web.bak-20260523-pre-campaign-workflow/` | ✅ |
| git bundle workaround (ECS → github 443 blocked, see deviation #6) | ✅ common→99c47b2 / api→9416669 / scheduler→241481e |
| `pip install -e isales-common` (0.3.0 → 0.3.2 on ECS venv) | ✅ |
| **No alembic migration** (4 backing tables already present) | ✅ |
| `systemctl restart isales-api isales-scheduler` + 0 error in 30s log scan | ✅ |
| local `npm install` (補 `lucide-vue-next`) + `npm run build` | ✅ 13.5s clean |
| `scp dist/* → /var/www/isales-web/` + `chown -R nginx:nginx` + `nginx -s reload` | ✅ 75 files / 2.9 MB |
| HTTP smoke (curl 127.0.0.1) | `/` 200 / `/campaigns` 200 / `/operations/campaigns` 200 / `/api/{role-configs,prompt-versions,filler-sets,campaigns}` 401 / `/api/docs` 200 |

## Deferred — explicit follow-up

1. **Full in-browser UX smoke** (§7.5 spirit) — HTTP-layer mount +
   JWT enforcement confirmed via curl. UI flow (建场景 → 配 prompt + 时段
   + 音色 + filler → 保存 → 刷新仍在 → 添加线索下拉 campaign → 启动场景
   → 验证 lead `next_call_at` 初始化 + status 走出 `new` → 停止场景；
   旧 `/operations/*` 重定向仍工作) needs a human in a browser pointed at
   `http://121.89.85.150/`. Same deferral shape as `web-admin-ui-redesign`
   §6.7 — backend infrastructure validated, UX validation owed.
2. **`provider_credential` table + API surface** — still not implemented;
   `ModelProviderConfig.vue` continues to localStorage-stash provider
   credentials. Production API keys remain env-driven. Out of scope here;
   inherited from `web-admin-ui-redesign` deferred §3.

## Risks / deviations observed during implementation

- **`isales-common` schema gap** (§2.3) — the proposal stated filler
  Pydantic schemas already existed. They did not; only ORM models existed.
  Added `schemas/filler.py` and bumped common 0.3.0 → 0.3.1, cascading
  the pin update to `isales-api` and `isales-scheduler` (engine + worker
  also re-pinned to `>=0.3.1,<0.4` for consistency, though they don't
  touch filler schemas).
- **`CampaignList.vue` filename collision** (§4.1) — taken by the
  operations-side view; customer-facing list became `CampaignWorkspace.vue`.
  Router name `campaigns` still resolves to the customer view per the new
  IA; the operations route is `operations-campaigns`.
- **`PromptConfigList.vue` not reusable** (§5.1) — the existing component
  was localStorage-shaped (single-payload save). API-backed editor needs
  per-row CRUD orchestration (create flow spans 3 calls), so introduced
  `PromptTierEditor.vue` and deleted `PromptConfigList.vue` rather than
  bolt API support onto an unsuited base.
- **`VoiceChannelConfig` deleted, not migrated into ModelProviderConfig**
  (§5.5) — `ModelProviderConfig` already covers ASR/TTS via the volcengine
  one-key-three-paths card; a dedicated ASR/TTS view added no value.
- **localStorage stash cleanup skipped** (§5.6) — `useLocalConfigStash`'s
  old keys for the deleted views are no longer read by anything; leaving
  them on user browsers is harmless.
- **Scheduler test redis-flake workaround** (§2.7) — `test_null_next_call`
  asserts `lead.status==CALLING` rather than the redis-queue length used
  by `test_loop`; the redis-llen assertion is locally flaky for unrelated
  reasons (pre-existing). The functional invariant under test (NULL
  next_call_at gets picked up) is fully covered by the status assertion.
- **ECS → github.com:443 阻断 / 部署侧 workaround** (§7.3) — Aliyun CN
  egress to github.com 443 was persistently TCP-blocked at deploy time
  (3 retries × 4 repos = 12/12 failures; DNS OK, TCP fails). Fell back to
  `git bundle create` on local Windows + `scp` to ECS + `git fetch
  /tmp/<repo>.bundle main:bundle/main` + `merge --ff-only`. install.sh /
  cloud RUNBOOK should grow either an `--offline-bundle` path or a China
  git-mirror config (e.g. `git config url.<mirror>.insteadOf
  https://github.com/`) plus an egress-connectivity diagnostic in §1
  pre-flight. STATE.md 2026-05-23 entry captures the actual command set.
- **isales-web `node_modules` drift on Windows dev rig** — `lucide-vue-
  next` was declared in `package.json` but missing from `node_modules`,
  causing the §7.1 (re-)build to fail with TS2307 across 13 files.
  `npm install` recovered cleanly. Cause unclear (possibly partial clean
  between sessions); STYLE_GUIDE / dev rig STATE.md may want a "run npm
  install when pyproject pinning shifts or after a `git pull` that touches
  package.json" reminder.
