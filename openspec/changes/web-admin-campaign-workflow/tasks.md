## 1. 前置依赖

- [ ] 1.1 归档 `web-admin-ui-redesign`（完成其 §6.7 浏览器烟测 + §7.6
  `openspec archive`），使 `web-admin-ui` capability 合并进
  `openspec/specs/web-admin-ui/`，本 change 的 delta 才有基底
- [ ] 1.2 确认 design.md Open Question §1：`retry-followup` spec 是否需补一条
  "campaign 启动时 api 初始化首呼 `next_call_at`" 的 Scenario；若需要，按
  openspec 流程把该 delta 并入本 change 或单独处理

## 2. 后端 — isales-api admin 端点 + campaign 启动初始化

- [ ] 2.1 在 `isales-api/isales_api/routers/` 新增 `role_configs.py`：
  `role_config` 的 GET 列表（按 `campaign_id` + `kind` 过滤）/ POST / GET /
  PATCH / DELETE，JWT 鉴权，分页对齐 `leads.py`
- [ ] 2.2 新增 `prompt_versions.py`：`prompt_version` 的 CRUD（按
  `scope_type` / `scope_id` 过滤），支持设 `is_active`
- [ ] 2.3 新增 `filler_sets.py`：`filler_set` + `filler_phrase` 的 CRUD（按
  `campaign_id` 过滤），filler_phrase 嵌套于 filler_set
- [ ] 2.4 把 3 个新 router 挂到 `isales-api` 主 app（`main.py`）
- [ ] 2.5 在 campaign start 流程（`campaigns.py` 的 `/campaigns/{id}/start`）
  增加：启动时把该 campaign 下 `status='new'` 且 `next_call_at IS NULL` 的
  lead 批量 `SET next_call_at = now`（同一事务）
- [ ] 2.6 在 `isales-api/tests/` 写 pytest：3 组 admin 端点的 CRUD + 鉴权 +
  campaign-id 过滤；campaign start 后验证 new 线索的 `next_call_at` 被初始化
- [ ] 2.7 `make test-all` 中 `isales-api` 全绿

## 3. 前端 — 信息架构（TopNav + router）

- [ ] 3.1 改 `isales-web/src/components/TopNav.vue`：主入口 3 → 4
  `[场景｜线索｜外呼｜预约]`，"场景"在最左；配置圆按钮 3 → 1（仅模型厂商）
- [ ] 3.2 改 `router/index.ts`：新增 `/campaigns`（客户面场景列表）+
  `/campaigns/:id`（场景详情）；移除 `/campaigns` → `/operations/campaigns`
  的重定向；运营面 campaign 高级编辑路由调整为 `/operations/campaigns/:id/edit`
- [ ] 3.3 移除独立的 `/config/ai-call`、`/config/voice-channels` 顶级路由
  （其功能将迁入 campaign 详情 / 降为全局配置）

## 4. 前端 — campaign 客户向 view

- [ ] 4.1 新增 `views/Campaigns/CampaignList.vue`（客户面）：campaign 卡片
  列表，每卡显示名称 / 启停状态徽标 / 归属线索数 / 外呼进度概览；"新建场景"
  入口；遵循 `isales-web/STYLE_GUIDE.md` 卡片模式
- [ ] 4.2 新增 `views/Campaigns/CampaignDetail.vue`：场景详情页，分区展示
  基本信息 + per-campaign 配置区（§5）+ 启停控制 + 外呼进度
- [ ] 4.3 CampaignDetail 的"启动场景 / 停止场景"按钮接
  `POST /api/campaigns/{id}/start|pause`；成功后刷新启停状态
- [ ] 4.4 客户面 campaign 详情仅暴露工作流必需字段（名称 / 音色 / prompt /
  垫词 / 时段 / 并发 / 启停）；高级字段保留在运营面 `CampaignEdit.vue`
- [ ] 4.5 CampaignDetail 外呼进度概览的数据来源（确认 design Open Q §3：
  复用 `analytics` 端点或新增按 campaign 聚合查询）

## 5. 前端 — per-campaign 外呼策略配置

- [ ] 5.1 把 `AICallConfig.vue` 的 4-tier 并行 prompt 编辑逻辑迁入
  CampaignDetail，复用 `components/Config/PromptConfigList.vue`；数据源从
  localStorage 改为 §2.1/§2.2 的 admin API（按 `campaign_id` 读写
  `role_config` + `prompt_version`）
- [ ] 5.2 把可拨时段编辑迁入 CampaignDetail，写入 `campaign.time_windows`
  （通过 `PATCH /api/campaigns/{id}`）
- [ ] 5.3 CampaignDetail 增加"选用音色"——从全局音色库（`voice_model`）下拉
  选择，写入 `campaign.voice_id`
- [ ] 5.4 把垫词配置迁入 CampaignDetail，接 §2.3 的 `filler_set` /
  `filler_phrase` admin API
- [ ] 5.5 `VoiceChannelConfig.vue` 拆分：ASR/TTS provider 部分降为全局配置
  view（保留路由或并入运营面）；音色库增删并入运营面
  `views/VoiceModels/VoiceModelList.vue`
- [ ] 5.6 删除独立全局 `AICallConfig.vue`；清理 `useLocalConfigStash` 中
  AI 外呼配置相关的 localStorage key
- [ ] 5.7 新增前端 api 模块：`api/roleConfigs.ts` / `api/promptVersions.ts` /
  `api/fillers.ts` 对接 §2 的端点

## 6. 前端 — 线索流程对接

- [ ] 6.1 `LeadEditDialog.vue`：把"任务 ID"数字输入框换成 campaign 下拉
  选择器，选项显示 campaign 名 + 启停状态；选中未启动 campaign 时给提示
- [ ] 6.2 `LeadEditDialog`：系统无 campaign 时提示先建场景 + 跳转链接
- [ ] 6.3 `LeadList.vue`：移除卡片上的"外呼"按钮（删除 `onDial` 及其
  `queued` 写入），卡片操作回归编辑 / 删除
- [ ] 6.4 `LeadList` 顶部的"AI 可用状态横幅"措辞调整：外呼由 campaign 启停
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
