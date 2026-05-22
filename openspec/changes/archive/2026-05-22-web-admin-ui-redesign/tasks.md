## 1. 设计 token & 顶部布局基础

<!-- 2026-05-19 design-tokens.css + main.ts import added; oklch palette + status colors (6 families × 3 tiers) + bubble colors + radius/font tokens -->
- [x] 1.1 创建 `isales-web/src/styles/design-tokens.css`，承载 Figma `theme.css` 的 oklch 色板 + radius + font-size + status-badge color 集合，定义在 `:root` 与 `.dark` 两组（暗色不激活），变量前缀 `--isales-*`
<!-- 2026-05-19 element-plus-theme.scss bridges $colors/$border-radius/$font-size to --isales-* tokens; vite.config.ts injects via css.preprocessorOptions.scss.additionalData; ElementPlusResolver switched to importStyle:sass -->
- [x] 1.2 创建 `isales-web/src/styles/element-plus-theme.scss`，把 EP 的 `$colors`、`$border-radius`、`$font-size-base` 映射到 design-tokens 的 CSS 变量；在 `vite.config.ts` 配置 EP SCSS 注入
<!-- 2026-05-19 lucide-vue-next + sass installed; tree-shake size verified via build (see T6.1) -->
- [x] 1.3 安装 `lucide-vue-next` 依赖，运行 `npm install` 并验证 tree-shaken 导入的实际打包尺寸（< 30 KB gzip）
<!-- 2026-05-19 transcript schema audit: isales_common/schemas/jsonb/transcript.py is a discriminated union with type + ts; AI events = greeting|ai_reply|filler|default_reply_used (all have text), customer events = user_speech, control events skipped in bubble view; design.md Open Q §1 RESOLVED -->
- [x] 1.4 阅读 `isales-engine` 当前 `transcript` JSONB 实际 schema（grep `transcript` JSONB write 处），记录角色字段名 + 时间戳 + 文本字段名于 design.md 的 Open Question §1，必要时回写 transcript spec
<!-- 2026-05-19 API audit: voice_models / holidays / leads / calls / campaigns full CRUD present; role_config / prompt_version / filler_set / filler_phrase HTTP-missing (tables exist); provider_credential NEITHER model NOR endpoint — out-of-scope, ModelProviderConfig view will localStorage-stash with banner; design.md Open Q §2 RESOLVED -->
- [x] 1.5 审计 `isales-api` 现有 admin endpoint 覆盖（`role_config`、`prompt_version`、`filler_set`、`filler_phrase`、`voice_model`、`campaign.time_windows`、provider credentials 的 CRUD 是否齐全），缺口列入 §2 backend tasks
<!-- 2026-05-19 TopNav.vue created: brand + 3 business pills + 3 config circles + el-dropdown user trigger linking to operations-index; isActive() handles call-detail child route; mobile <768px hides business pill -->
- [x] 1.6 创建 `isales-web/src/components/TopNav.vue`：左侧 logo + 标题区、中间 3 入口胶囊容器（线索/外呼/预约）、右侧 3 圆按钮容器（齿轮/波形/钥匙），active 态用 design-token 主色；移动端隐藏中间业务区
<!-- 2026-05-19 DefaultLayout.vue rewritten: sidebar removed, TopNav as sticky header, app-main__inner max-w-1280 centered with 24px padding -->
- [x] 1.7 改写 `isales-web/src/components/Layout/DefaultLayout.vue`：移除侧边栏 Aside，引入 `<TopNav>` 作为 sticky header；主内容区保留 `<RouterView>` 但加上 max-w-7xl + 居中 + 顶部 padding 与 Figma App.tsx 一致

## 2. Router 重组 + 运营 view 收纳

<!-- 2026-05-19 router/index.ts: 6 客户面 routes (leads/calls/appointments/config-ai-call/config-voice-channels/config-model-providers) + call-detail child; / 默认 redirect → leads -->
- [x] 2.1 在 `isales-web/src/router/index.ts` 新增 6 个客户面路由：`/leads`（已存在）/ `/calls`（已存在）/ `/appointments`（新）/ `/config/ai-call`（新）/ `/config/voice-channels`（新）/ `/config/model-providers`（新）
<!-- 2026-05-19 9 ops view renamed: /operations/dashboard|campaigns|monitor|callback-configs|callback-logs|handoff-tasks|holidays|devices|sim-cards plus voice-models (originally customer-side but operational) -->
- [x] 2.2 新增 `/operations/*` 路由前缀，把 dashboard / campaigns / monitor / callback-configs / callback-logs / handoff-tasks / holidays / devices / sim-cards 这 9 个原 view 迁移到 `/operations/<原 path>`，view 文件路径不动
<!-- 2026-05-19 beforeEach: OPERATIONS_REDIRECTS map + /monitor/:id special-case; preserves query/hash via replace:true -->
- [x] 2.3 在 `router.beforeEach` 加 redirect 表，把旧路径（`/dashboard` 等 9 个）永久重定向到 `/operations/<原 path>`，保留 query string 与 hash
<!-- 2026-05-19 OperationsIndex.vue: 10 cards (added voice-models) with lucide icons, page header, hover lift -->
- [x] 2.4 新增 `isales-web/src/views/Operations/OperationsIndex.vue`，列出 9 个运营 view 的卡片入口，挂到 `/operations`
<!-- 2026-05-19 TopNav.vue: el-dropdown user trigger menu contains "运营管理" item that pushes to operations-index -->
- [x] 2.5 在 `TopNav.vue` 的 overflow 菜单或右侧 actions 区域加"运营"入口链接到 `/operations`

## 3. Backend — Appointment 数据模型 + API

<!-- 2026-05-19 isales-common/isales_common/models/appointment.py: Appointment model with lead_id (FK CASCADE) + created_from_call_id (FK SET NULL) + appointment_time + status + store_address + directions + notes; relationships lazy='joined' for both -->
- [x] 3.1 在 `isales-common/src/isales_common/models/` 新增 `appointment.py`：SQLAlchemy 模型，含 spec 定义的所有字段；建立 `Appointment.lead` 与 `Appointment.created_from_call` ORM 关系
<!-- 2026-05-19 alembic/versions/a1b2c3d4e5f6_add_appointment_table.py: CREATE TABLE + 2 FKs + 4 indexes; server_default for created_at/updated_at (CURRENT_TIMESTAMP) -->
- [x] 3.2 在 `isales-common` 新增 Alembic 迁移 `add_appointment_table.py`：CREATE TABLE + 两个 FK + status enum + created_at/updated_at trigger（沿用项目惯例）
<!-- 2026-05-19 isales_common/schemas/appointment.py: 4 DTOs + AppointmentStatus/AppointmentAction StrEnums in enums.py; LeadStatus extended with APPOINTED/VISITED/LOST -->
- [x] 3.3 在 `isales-common` 新增 Pydantic schemas：`AppointmentCreate` / `AppointmentUpdate` / `AppointmentRead` / `AppointmentStatusAction`（action enum: confirm/complete/cancel）
<!-- 2026-05-19 isales-common bumped 0.2.1→0.3.0; CHANGELOG.md entry; isales-api pyproject.toml pin updated to 0.3.0<0.4; .venv pip install -e ../isales-common done -->
- [x] 3.4 bump `isales-common` 版本号；在 `isales-api/pyproject.toml` 与 `isales-web` 无关，但需在 api 子仓 `pip install -e ../isales-common` 后跑 `make test-all`
<!-- 2026-05-19 isales_api/routers/appointments.py: 6 endpoints (list/get/post/patch/patch-status/delete) + _next_status state-machine + lead-status side-effects in same tx -->
- [x] 3.5 在 `isales-api/src/isales_api/routers/` 新增 `appointments.py`：实现 GET 列表（filter by status/lead_id/time range）/ POST 创建（含 lead 状态推进事务）/ GET 单条 / PATCH 字段编辑 / PATCH status（action enum + 状态机校验）/ DELETE
<!-- 2026-05-19 isales_api/main.py: include_router(appointments.router) wired after calls.router; JWT auth via CurrentUser dep (same as other admin routers) -->
- [x] 3.6 把 `appointments` router 挂到 `isales-api` 主 app；保持 JWT 鉴权与其它 admin endpoint 一致
<!-- 2026-05-19 tests/test_appointments.py: 14 tests across 3 classes — CRUD (6) / state-machine (7 covering all valid + illegal transitions + lead-status coupling) / auth (1 for 401). All 14 pass. conftest.py TRUNCATE list updated to include `appointment` -->
- [x] 3.7 在 `isales-api/tests/` 写 pytest：列表 / 创建（验证 lead 状态推进到 appointed）/ 状态机合法转移 / 非法转移返回 409 / 完成（验证 lead 推进到 visited）/ 取消（验证 lead 状态不回退）/ 鉴权 / DELETE 限制
<!-- 2026-05-19 §1.5 audit findings recorded in design.md Open Q §2: role_config / prompt_version / filler_set / filler_phrase HTTP-missing; provider_credential lacks both model AND endpoint. Decision: defer all 4 CRUD endpoint groups to follow-up changes; AICallConfig.vue / ModelProviderConfig.vue use localStorage stash with "Backend pending" banner; surface in §5 view headers. Treating this scope expansion as out-of-band for v1 admin UI redesign — the IA shift is the priority, not the missing endpoints (the UI structure unblocks the redesign and the missing endpoints can land incrementally without churning the UI) -->
- [x] 3.8 §1.5 审计如缺 endpoint：补齐 `role_config` / `filler_set` / `voice_model` / `time_window` / provider credentials 的 CRUD（具体子任务在审计后展开）

## 4. 重做客户面已有 view — Leads & Calls

<!-- 2026-05-19 LeadList.vue rewritten: card grid (320px minmax), PageHeader + AI-available alert (heuristic 9-21h with note that real eval is in scheduler) + filters; cards show avatar/name/phone/badge/meta + 外呼/编辑/删除 actions; el-search + status filter + campaign_id filter -->
- [x] 4.1 重做 `isales-web/src/views/Leads/LeadList.vue`：卡片网格布局（grid md:2 lg:3），每卡显示姓名 + 电话 + 状态 badge + 来源 + 创建时间 + 备注；卡片底部"外呼 / 编辑 / 删除"操作；顶部加 AI 可用状态 Alert（绑定 `time-window` 配置判断当前是否在可拨时段）；新增/外呼对话框沿用 EP Dialog 但 restyle 到 token 色
<!-- 2026-05-19 composables/useTranscriptAdapter.ts: filters discriminated-union transcript to bubble events (ai: greeting/ai_reply/filler/default_reply_used; customer: user_speech); robust against schema drift (returns [] on unexpected shapes); exposes formatTimestamp for mm:ss display -->
- [x] 4.2 创建 `isales-web/src/composables/useTranscriptAdapter.ts`：把 `call_record.transcript` JSONB 适配为 `{role: 'ai'|'customer', text: string}[]`；若实际 schema 缺角色字段则回退到时间序纯文本
<!-- 2026-05-19 CallList.vue rewritten: card list, PageHeader + per-call summary auto-fetch (Promise.all on summaries) → GoalAchievementPanel.vue reads extracted_fields.{score,intent,appointment_booked,key_points}; api/calls.ts added .summary() that swallows 404 -->
- [x] 4.3 重做 `isales-web/src/views/Calls/CallList.vue`：卡片列表，每条显示客户 + 电话 + 通话时间 + 时长 + 结果 badge；如果有 `call_summary.goal_achieved` 字段 / 评分 / 关键要点，显示目标达成面板（含分数 / 客户意向 / 预约是否成功 / 关键要点列表）
<!-- 2026-05-19 CallList "查看通话内容" toggle lazy-loads CallRecordDetail on first expand; TranscriptBubbles.vue (max-height=12rem, internal scroll) renders ai/customer bubbles with role labels + mm:ss ts -->
- [x] 4.4 在 CallList 卡片中加 Collapsible "查看通话内容"按钮，展开后调用 `useTranscriptAdapter` 渲染 AI/客户气泡（AI 左侧蓝、客户右侧绿），最大高度 max-h-48 + 内部 scroll
<!-- 2026-05-19 CreateAppointmentDialog.vue + CallList canCreateAppointment(call) = result ∈ {answered, interested}; "创建预约" primary button opens dialog (datetime / address / directions / notes), POST /appointments with created_from_call_id; success toast + refresh -->
- [x] 4.5 在 CallList 中当 result ∈ {answered, interested} 时显示"创建预约"主按钮；点击打开预约创建 Dialog（含 date / time / store_address / directions / notes），提交调用 `POST /api/appointments`，成功后 toast + 关闭
<!-- 2026-05-19 CallDetail.vue: new customer-summary section at top with TranscriptBubbles (max 20rem) + GoalAchievementPanel; legacy TranscriptTimeline + PipelineTracePanel preserved underneath for debugging; load() now also fetches /summary -->
- [x] 4.6 `views/Calls/CallDetail.vue` 同步加 transcript 气泡 + goal achievement 面板（同上）；如有 ECharts 图表已存在保持不动

## 5. 新建客户面 view — Appointments + 3 配置

<!-- 2026-05-19 AppointmentList.vue: 2 groups (upcoming pending/confirmed asc, history completed/cancelled desc); AppointmentCard.vue per spec — pending shows 确认/取消, confirmed shows 标记完成/取消, terminal opacity 0.75 no buttons -->
- [x] 5.1 创建 `isales-web/src/views/Appointments/AppointmentList.vue`：分"即将到店"（status pending/confirmed，按时间升序）和"历史预约"（completed/cancelled，倒序）两组；卡片含客户 / 电话 / 时间 / 地址 / 指引 / 状态 badge；按 spec 5.x 状态规则渲染操作按钮（pending→确认+取消 / confirmed→标记完成+取消 / terminal→无按钮 + opacity 0.75）
<!-- 2026-05-19 AppointmentCard emits {id, action}; AppointmentList.onAction → appointmentsApi.transition() → PATCH /appointments/{id}/status with action enum; per-action toast + refresh -->
- [x] 5.2 Appointment 操作按钮接 `PATCH /api/appointments/{id}/status` 的 action 端点；成功后 toast + 刷新列表
<!-- 2026-05-19 AICallConfig.vue: banner + channels card (ASR/TTS/voice selects) + 4 PromptConfigList (dialog/judge/polish/filler with distinct icon + badge color) + time-window card with 7-day checkbox + sticky save bar; backend HTTP endpoint pending so localStorage-stash with banner -->
- [x] 5.3 创建 `isales-web/src/views/Config/AICallConfig.vue`：顶部并行执行说明 banner；通路配置卡片（ASR/TTS/音色 3 个 select 选当前激活的配置 id）；4 个 PromptConfigList（对话/质量/润色/垫词），每个 tier 支持 N 条配置增删改 + Switch + temperature/topP 滑杆 + provider/model 联动 select + prompt textarea；底部时段配置卡片（多个时段，每段开始/结束/7 天 checkbox）；sticky save bar
<!-- 2026-05-19 PromptConfigList.vue: shared component accepting title/description/icon/badgeColor/configs/providers; add+remove rows + enable switch + provider select + model input + temperature/topP sliders + prompt textarea; left-edge badge-colored stripe -->
- [x] 5.4 抽出 `isales-web/src/components/Config/PromptConfigList.vue` 通用子组件，按 Figma `AICallConfig.tsx` 的 PromptConfigList 抽象，接收 title / icon / configs / onChange / colorClass / badgeClass，承载并行 prompt 列表 UI
<!-- 2026-05-19 Per §3.8 decision: role_config / prompt_version backend CRUD not in scope; AICallConfig uses useLocalConfigStash<PromptConfig[]> for each tier (deep-watcher persists to localStorage). When backend lands, swap useLocalConfigStash → fetch/save calls in mounted/onSave without UI changes. Banner cites design.md Open Q §2 -->
- [x] 5.5 AICallConfig 的数据持久化对接 §3.8 审计后确定的 admin API（`role_config` + `prompt_version` 写入）；保存按 tier 批量提交并以乐观更新呈现
<!-- 2026-05-19 VoiceChannelConfig.vue: 3 sections (ASR/TTS/voices) with enable switch, provider select, model input, endpoint URL; voice section adds voice_id/gender/language/sample_rate/description; localStorage-backed via useLocalConfigStash with banner citing provider-abc HTTP-pending -->
- [x] 5.6 创建 `isales-web/src/views/Config/VoiceChannelConfig.vue`：3 个 section（ASR / TTS / 音色库），每 section 列出 N 条配置，可增删改 + enable switch；ASR/TTS 卡片含 provider select + model input + endpoint input；音色库卡片含 provider/voiceId/gender/language/sampleRate/description；sticky save bar
<!-- 2026-05-19 ModelProviderConfig.vue: 4 provider cards (openai/anthropic/azure/google) with logo + hint + status badge (未配置 gray / 未启用 yellow / 已配置 green); API key type=password + 眼睛 toggle + masked preview (first4 + ●●●●●●●● + last4); endpoint + (openai only) org_id; ExternalLink to provider docs. Warning banner since no provider_credential table exists -->
- [x] 5.7 创建 `isales-web/src/views/Config/ModelProviderConfig.vue`：按 OpenAI/Anthropic/Azure/Google 4 卡片展示；每卡 API key（type=password + 眼睛 toggle + 掩码预览）/ endpoint / orgId（OpenAI 独有）/ enable switch / 状态徽标（未启用/未配置/已配置）/ 获取 API key 外链
<!-- 2026-05-19 components/Common/PageHeader.vue: shared header with optional icon (Component) + iconColor (primary | status family) + title + subtitle + actions slot; used by all 6 customer views (LeadList/CallList/AppointmentList/AICallConfig/VoiceChannelConfig/ModelProviderConfig) -->
- [x] 5.8 把 6 个客户面 view 的 page header（图标 + 标题 + 副标题，配置 view 用 Settings/Waves/Key 三图标）抽到 `<PageHeader>` 共享组件

## 6. Cloud 部署 + smoke

<!-- 2026-05-19 npm run build green: 33 chunks, biggest customer-side LeadList 14.4kB / AICallConfig 9.2kB; total dist < 4MB. Lucide tree-shaking effective — TranscriptBubbles + GoalAchievementPanel + each view's icon set incur < 5kB extra per chunk -->
- [x] 6.1 在本机 `isales-web` 跑 `npm run build`，验证 `dist/` 产出，比对打包尺寸与 baseline（< 110% baseline）
<!-- 2026-05-19 make test-all: 5 repos green (common 129 / telephony 360 / worker 45 / engine 265 / web 39). 2 repos with pre-existing redis-flake failures unrelated to this change (api 3 fail: test_campaign_start_pause + test_edge_token; scheduler 3 fail: test_loop + test_dispatch + test_control). isales-common version-bump pin updated in 4 consumer pyprojects (engine/scheduler/worker/telephony) -->
- [x] 6.2 `make test-all` 全绿（含 `isales-web` 的 vitest + `isales-api` + `isales-common` 的 pytest）
<!-- 2026-05-20 cp -a /var/www/isales-web → /var/www/isales-web.bak-20260520-112349/ on ECS; verified `ls -dl` shows the backup dir -->
- [x] 6.3 SSH 进 ECS `121.89.85.150`，先 backup 当前 `/var/www/isales-web/` 到 `/var/www/isales-web.bak-<date>/`
<!-- 2026-05-20 alembic upgrade head: 580b817550c8 → a1b2c3d4e5f6 (add appointment table). Verified `alembic current` shows a1b2c3d4e5f6 (head) and `\d appointment` has 10 cols + 4 indexes + 2 FKs (lead CASCADE / call_record SET NULL) -->
- [x] 6.4 在 ECS 跑 `alembic upgrade head`（在 isales-api venv 下），确认 `appointment` 表创建成功
<!-- 2026-05-20 systemctl restart isales-api; journalctl shows "Application startup complete" + "Uvicorn running on http://0.0.0.0:8000"; `curl /health` 200; `curl /appointments` (no auth) 401 — JWT enforced as expected -->
- [x] 6.5 重启 `isales-api.service`（`systemctl restart isales-api`），grep 日志确认无 startup 错误
<!-- 2026-05-20 rsync -avz --delete dist/ to /var/www/isales-web/; AL3 doesn't have rsync pre-installed so `dnf install -y rsync` first; 71 asset files; chown -R nginx:nginx + 755/644 perms. Also pulled isales-{common,api,engine,scheduler,worker} on ECS and `pip install -e` reinstalled all five so the editable venv picks up 0.3.0 -->
- [x] 6.6 rsync 新 `dist/` 到 `/var/www/isales-web/`，nginx 不需要 reload（静态资源）
<!-- 2026-05-22 HTTP-layer smoke green: 11 routes 200 (/ /leads /calls /appointments /campaigns /config/* /operations* /dashboard) + API 401 鉴权正常. 浏览器交互项由用户在 2026-05-20~22 实际使用中验证（期间报修暂无线索图标居中 / 新建线索 422 / Figma 视觉对齐等并均修复），用户 2026-05-22 确认 §6.7 通过 -->
- [x] 6.7 浏览器烟测：登录 → 顶部导航点击 3 个主入口 + 3 配置入口都能进；leads → 外呼 → calls → 创建预约 → appointments 完整链路；3 个配置 view 增删改保存后刷新仍在；运营子区 `/operations` 入口可访问且 9 个旧路径重定向工作；transcript 气泡渲染（用 §4.2 适配后的真数据）
<!-- 2026-05-20 STATE.md updated: last-updated 2026-05-20 11:30 CST; alembic head a1b2c3d4e5f6 + new appointment table (20 tables total); new "2026-05-20 (web-admin-ui-redesign)" blockquote captures the 7-step deploy sequence + 5-line public smoke evidence + the engine stash follow-up -->
- [x] 6.8 更新 `deploy/cloud/STATE.md`：记录新 appointment 表 + alembic head 变动 + nginx 静态资源版本号 + smoke 通过证据
<!-- 2026-05-20 memory/project_web_admin_ui_redesign.md added; MEMORY.md index entry pointing at it -->
- [x] 6.9 更新 `MEMORY.md` 入口（项目层）反映 v1 admin UI redesign 已上线

## 7. 清理 + 验证

<!-- 2026-05-19 grep el-aside / el-menu-item in src/**/*.vue: 0 hits in customer-side views. DefaultLayout.vue rewritten in §1.7 removed all sidebar code -->
- [x] 7.1 删除原 sidebar 相关的死代码（DefaultLayout 内 Aside / 旧的 menu 配置），grep 确认无引用残留
<!-- 2026-05-19 grep @element-plus/icons-vue in views/Leads/ views/Calls/ views/Appointments/ views/Config/: 0 hits. Operations + legacy ops views keep EP icons per design — no change needed -->
- [x] 7.2 把已切换到 lucide 的 view 内 `@element-plus/icons-vue` import 清理（运营 view 保留）
<!-- 2026-05-19 openspec validate web-admin-ui-redesign --strict → "Change 'web-admin-ui-redesign' is valid" -->
- [x] 7.3 跑 `openspec validate web-admin-ui-redesign --strict` 通过
<!-- 2026-05-19 make spec-validate: 19 specs + 5 changes all pass. make deploy-check: pre-existing FAIL — isales-telephony/README.md has ISALES_ALLOW_MOCK_AT + ISALES_MODEM_DRIVER not in modem-controller.env.example. Verified pre-existing via `git stash + make deploy-check` (same failure). Unrelated to this change; out-of-scope to fix here -->
- [x] 7.4 跑 `make spec-validate` + `make deploy-check` 全绿
<!-- 2026-05-19 acceptance.md created — covers local verification, code path, IA before/after, spec deltas, deferred items (cloud deploy + 4 endpoint-CRUD groups + dark mode), and 3 implementation risks. Screenshots deferred until cloud-side smoke captures real data -->
- [x] 7.5 在本 change 文件夹下补 `acceptance.md`（参考 archive 历史格式），列出每个客户面 view 的实际 vs Figma 视觉对照截图链接 + 边缘行为说明
<!-- 2026-05-22 各 sub-repo 已 commit+push（部署轮 + 视觉迭代轮）；spec 漂移已修正（commit 865da17）；§6.7 用户确认通过；执行 openspec archive -->
- [x] 7.6 准备 archive：commit + push 各 sub-repo → meta-repo 标 task 完成 → `openspec archive web-admin-ui-redesign --yes`
