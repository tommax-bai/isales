## 1. 前置依赖

- [x] 1.1 归档 `web-admin-ui-redesign`——已于 2026-05-22 `openspec archive`，
  `web-admin-ui` capability 已并入 `openspec/specs/web-admin-ui/`，本 change
  的 delta 基底就绪（design.md 3 个 Open Question 均已 RESOLVED）

## 2. 后端 — isales-api 端点 + scheduler 取数

<!-- 2026-05-22 routers/role_configs.py: list(campaign_id + kind 过滤) / get / post / patch / delete -->
- [x] 2.1 在 `isales-api/isales_api/routers/` 新增 `role_configs.py`：
  `role_config` 的 GET 列表（按 `campaign_id` + `kind` 过滤）/ POST / GET /
  PATCH / DELETE，JWT 鉴权，分页对齐 `leads.py`
<!-- 2026-05-22 routers/prompt_versions.py: CRUD + _deactivate_siblings（设 is_active 时同 scope 其余置 false） -->
- [x] 2.2 新增 `prompt_versions.py`：`prompt_version` 的 CRUD（按
  `scope_type` / `scope_id` 过滤），支持设 `is_active`
<!-- 2026-05-22 routers/filler_sets.py: filler_set CRUD + 嵌套 /filler-sets/{id}/phrases。偏差：isales-common 无 filler 的 Pydantic schema（proposal 误判"已存在"），新增 schemas/filler.py + bump common 0.3.0→0.3.1 -->
- [x] 2.3 新增 `filler_sets.py`：`filler_set` + `filler_phrase` 的 CRUD（按
  `campaign_id` 过滤），filler_phrase 嵌套于 filler_set
<!-- 2026-05-22 campaigns.py + GET /campaigns/{id}/progress；CampaignProgress schema 加在 isales_api/schemas.py -->
- [x] 2.4 在 `campaigns.py` 新增 `GET /campaigns/{id}/progress`：按
  `lead.status` GROUP BY 聚合返回该 campaign 的线索状态分布
<!-- 2026-05-22 main.py include_router: role_configs / prompt_versions / filler_sets -->
- [x] 2.5 把新 router 挂到 `isales-api` 主 app（`main.py`）
<!-- 2026-05-22 loop.py: where 改 Lead.next_call_at.is_(None) | (Lead.next_call_at <= now) -->
- [x] 2.6 `isales-scheduler` 的 `loop.py` 取数 SQL：`next_call_at` 条件由
  `next_call_at <= now` 改为 `next_call_at IS NULL OR next_call_at <= now`
  （新线索 next_call_at 为空时视为立即可呼，retry-followup spec delta）
<!-- 2026-05-22 tests/test_campaign_configs.py (isales-api, 10 test) + tests/test_null_next_call.py (scheduler, 1 test)；conftest TRUNCATE 加 prompt_version。scheduler test 改用 lead.status=CALLING 断言（本地 redis llen flake，见 test_loop pre-existing） -->
- [x] 2.7 写 pytest：`isales-api` 3 组 admin 端点的 CRUD + 鉴权 +
  campaign-id 过滤 + progress 聚合；`isales-scheduler` 验证取数把
  `next_call_at IS NULL` 的 new 线索纳入候选
<!-- 2026-05-22 isales-api 88 passed（3 pre-existing redis/JWT flake）；isales-scheduler 37 passed（3 pre-existing redis flake）。新增 11 test 全绿 -->
- [x] 2.8 `make test-all` 中 `isales-api` + `isales-scheduler` 全绿

## 3. 前端 — 信息架构（TopNav + router）

<!-- 2026-05-22 TopNav.vue: businessEntries 加 campaigns(场景,Megaphone,最左)；configEntries 减为 1(模型厂商)；isActive 支持 campaign-* 子路由；import 去 Settings/Waves 加 Megaphone -->
- [x] 3.1 改 `isales-web/src/components/TopNav.vue`：主入口 3 → 4
  `[场景｜线索｜外呼｜预约]`，"场景"在最左；配置圆按钮 3 → 1（仅模型厂商）
<!-- 2026-05-22 router/index.ts: 客户面加 campaigns(CampaignWorkspace) + campaign-detail(CampaignDetail)；OPERATIONS_REDIRECTS 删 /campaigns（现为客户面路由）；运营面 operations-campaigns / operations-campaign-edit 路由不变 -->
- [x] 3.2 改 `router/index.ts`：新增 `/campaigns`（客户面场景列表）+
  `/campaigns/:id`（场景详情）；移除 `/campaigns` → `/operations/campaigns`
  的重定向；运营面 campaign 高级编辑路由调整为 `/operations/campaigns/:id/edit`
<!-- 2026-05-22 router 删 config-ai-call / config-voice-channels 两个 route。AICallConfig.vue / VoiceChannelConfig.vue 文件暂留（§5.5/§5.6 清理） -->
- [x] 3.3 移除独立的 `/config/ai-call`、`/config/voice-channels` 顶级路由
  （其功能将迁入 campaign 详情 / 降为全局配置）

## 4. 前端 — campaign 客户向 view

<!-- 2026-05-22 偏差：views/Campaigns/CampaignList.vue 已被运营面占用，客户面场景列表改用 views/Campaigns/CampaignWorkspace.vue。卡片网格 + 启停徽标(progress.is_active) + 线索数/进度 + 新建场景 dialog；遵循 STYLE_GUIDE -->
- [x] 4.1 新增 `views/Campaigns/CampaignList.vue`（客户面）：campaign 卡片
  列表，每卡显示名称 / 启停状态徽标 / 归属线索数 / 外呼进度概览；"新建场景"
  入口；遵循 `isales-web/STYLE_GUIDE.md` 卡片模式
<!-- 2026-05-22 CampaignDetail.vue: header(启停按钮) + 进度卡 + 基本信息(名称/并发) + 可拨时段编辑 + AI 外呼策略配置区(§5 填充前为 placeholder section) + sticky save bar -->
- [x] 4.2 新增 `views/Campaigns/CampaignDetail.vue`：场景详情页，分区展示
  基本信息 + per-campaign 配置区（§5）+ 启停控制 + 外呼进度
<!-- 2026-05-22 启动/停止按钮接 campaignsApi.start/pause；成功后 loadProgress() 刷新 is_active -->
- [x] 4.3 CampaignDetail 的"启动场景 / 停止场景"按钮接
  `POST /api/campaigns/{id}/start|pause`；成功后刷新启停状态
<!-- 2026-05-22 CampaignDetail 仅暴露 名称/并发/可拨时段（+§5 的 prompt/垫词/音色）；silence/interruption/transfer/retry 等高级字段不出现，留运营面 CampaignEdit -->
- [x] 4.4 客户面 campaign 详情仅暴露工作流必需字段（名称 / 音色 / prompt /
  垫词 / 时段 / 并发 / 启停）；高级字段保留在运营面 `CampaignEdit.vue`
<!-- 2026-05-22 进度卡接 campaignsApi.progress(id)：渲染 status_counts 分布。接通率/成交率（analytics）留 §5 一并接入 -->
- [x] 4.5 CampaignDetail 外呼进度概览：线索状态分布接 §2.4 的
  `GET /campaigns/{id}/progress`；接通率 / 成交率接 `analytics` 端点
  （带 `campaign_id` 过滤）

## 5. 前端 — per-campaign 外呼策略配置

<!-- 2026-05-22 偏差：未复用 PromptConfigList（localStorage 形态），新建 components/Campaign/PromptTierEditor.vue 封装 role_config + prompt_version CRUD 编排（新建=POST role_config→POST prompt_version→回填 current_prompt_version_id）。CampaignDetail 用 3 个（role/judge/polish）；每行独立保存 -->
- [x] 5.1 把 `AICallConfig.vue` 的 4-tier 并行 prompt 编辑逻辑迁入
  CampaignDetail，复用 `components/Config/PromptConfigList.vue`；数据源从
  localStorage 改为 §2.1/§2.2 的 admin API（按 `campaign_id` 读写
  `role_config` + `prompt_version`）
<!-- 2026-05-22 时段编辑在 §4.2 建 CampaignDetail 时已一并完成 -->
- [x] 5.2 把可拨时段编辑迁入 CampaignDetail，写入 `campaign.time_windows`
  （通过 `PATCH /api/campaigns/{id}`）
<!-- 2026-05-22 CampaignDetail 基本信息卡加「选用音色」select，voiceApi.list() 容忍 Page/裸数组，写 campaign.voice_id -->
- [x] 5.3 CampaignDetail 增加"选用音色"——从全局音色库（`voice_model`）下拉
  选择，写入 `campaign.voice_id`
<!-- 2026-05-22 components/Campaign/FillerEditor.vue：filler_set + filler_phrase 即时落 API -->
- [x] 5.4 把垫词配置迁入 CampaignDetail，接 §2.3 的 `filler_set` /
  `filler_phrase` admin API
<!-- 2026-05-22 偏差：VoiceChannelConfig.vue 直接删除而非"扩 ModelProviderConfig"——ModelProviderConfig 的 volcengine 卡片已涵盖 ASR/TTS 凭据（一套 key 三路通用），音色库由运营面 voice-models 承载 -->
- [x] 5.5 `VoiceChannelConfig.vue` 拆分：ASR/TTS provider 部分并入「模型
  厂商」view（`ModelProviderConfig.vue` 扩成统一的 AI 服务商凭据管理，含
  LLM / ASR / TTS provider）；音色库增删并入运营面
  `views/VoiceModels/VoiceModelList.vue`
<!-- 2026-05-22 删 AICallConfig.vue + VoiceChannelConfig.vue + PromptConfigList.vue（后者仅 AICallConfig 用，被 PromptTierEditor 取代）。localStorage 旧 key 无害不专门清理。STYLE_GUIDE §7 更新 -->
- [x] 5.6 删除独立全局 `AICallConfig.vue`；清理 `useLocalConfigStash` 中
  AI 外呼配置相关的 localStorage key
<!-- 2026-05-22 api/roleConfigs.ts + api/promptVersions.ts + api/fillers.ts + types/config.ts -->
- [x] 5.7 新增前端 api 模块：`api/roleConfigs.ts` / `api/promptVersions.ts` /
  `api/fillers.ts` 对接 §2 的端点

## 6. 前端 — 线索流程对接

<!-- 2026-05-22 LeadEditDialog: 任务 ID el-input-number → campaign el-select；dialog 打开时 loadCampaigns()（list + 各 progress 拿 is_active）；campaignLabel 显示「名（运行中/已停止）」；selectedInactive 时 dialog-hint 警告；编辑时 campaign 锁定 -->
- [x] 6.1 `LeadEditDialog.vue`：把"任务 ID"数字输入框换成 campaign 下拉
  选择器，选项显示 campaign 名 + 启停状态；选中未启动 campaign 时给提示
<!-- 2026-05-22 LeadEditDialog: campaigns 为空 → dialog-hint「系统还没有外呼场景」+ el-button 跳转 campaigns -->
- [x] 6.2 `LeadEditDialog`：系统无 campaign 时提示先建场景 + 跳转链接
<!-- 2026-05-22 LeadList: 删卡片「外呼」el-button + onDial 函数（含 queued 写入）；卡片操作改「编辑」主按钮 flex:1 + 删除 IconButton -->
- [x] 6.3 `LeadList.vue`：移除卡片上的"外呼"按钮（删除 `onDial` 及其
  `queued` 写入），卡片操作回归编辑 / 删除
<!-- 2026-05-22 LeadList 横幅去掉 9-21h 时段判定，改静态 info banner「外呼由场景驱动」+「前往场景」链接；aiAvailable computed 删除 -->
- [x] 6.4 `LeadList` 顶部的"AI 可用状态横幅"措辞调整：外呼由 campaign 启停
  驱动，横幅引导用户去场景启动

## 7. 部署 + smoke

- [ ] 7.1 本机 `isales-web` 跑 `npm run build` + `npm test` 全绿
- [ ] 7.2 `make test-all` 全绿（关注 `isales-api` 新端点）
- [ ] 7.3 SSH ECS `121.89.85.150`：`git pull` isales-api + isales-web；
  重装 isales-api venv；重启 `isales-api.service`，grep 日志无错
- [ ] 7.4 rsync 新 `dist/` 到 `/var/www/isales-web/`，修正 nginx 属主
- [ ] 7.5 浏览器烟测：建场景 → 配 prompt/时段/音色 → 保存刷新仍在 →
  添加线索（下拉选 campaign）→ 启动场景 → 验证线索 `next_call_at` 被初始化 →
  停止场景；旧 `/operations/*` 重定向仍工作
- [ ] 7.6 更新 `deploy/cloud/STATE.md`：记录新 admin 端点 + 无 DB 迁移 +
  smoke 证据

## 8. 清理 + 验证 + archive

- [ ] 8.1 grep 确认无残留：旧 `/config/ai-call`、`/config/voice-channels`
  路由引用、`AICallConfig.vue` 死引用、`queued` 写入点
- [ ] 8.2 更新 `isales-web/STYLE_GUIDE.md` §8 待收敛清单（配置 view 已收敛）
- [ ] 8.3 跑 `openspec validate web-admin-campaign-workflow --strict` 通过
- [ ] 8.4 跑 `make spec-validate` 全绿
- [ ] 8.5 补 `acceptance.md`（参考 archive 历史格式）
- [ ] 8.6 commit + push 各 sub-repo → meta-repo 标 task 完成 →
  `openspec archive web-admin-campaign-workflow --yes`
