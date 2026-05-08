> 实施在 isales-web 仓库（新建）。每组对应 1~2 个 PR，按顺序合入。
> 前端独立栈：Vue 3 + Vite + TypeScript + Element Plus + Pinia + Vue Router + axios + echarts + vitest。
> 不动后端任何 Python 服务（API endpoints 已就位）。

## 1. isales-web 仓库骨架（PR #1）✅

- [x] 1.1 git init + .gitignore（node_modules / dist / .env.local）
- [x] 1.2 package.json（vue@3.5 / vite@5.4 / element-plus@2.8 / pinia@3 / pinia-plugin-persistedstate@4 / vue-router@4 / axios / echarts + vue-echarts / dayjs / @vueuse/core / @element-plus/icons-vue）
- [x] 1.3 dev deps: typescript / @vue/tsconfig / vue-tsc / eslint + @vue/eslint-config-typescript / prettier / vitest + @vue/test-utils + jsdom / @testing-library/vue / unplugin-auto-import / unplugin-vue-components
- [x] 1.4 vite.config.ts：vue + Element Plus 自动导入 + @/ alias + dev proxy /api+/ws + vitest jsdom 配置（含 css: false + element-plus inline 解决 jsdom CSS 加载）
- [x] 1.5 tsconfig.json + tsconfig.node.json（@vue/tsconfig.dom + .node 继承）
- [x] 1.6 目录骨架 src/{router,stores,api,components/Layout,views,types,utils,assets} + tests + deploy
- [x] 1.7 README 部署章节 + 后续 PR 路线图；CI workflow 留 PR #11
- [x] 1.8 App.vue → DefaultLayout（侧边栏 + 顶栏 + main outlet）
- [x] 1.9 reset.css + 中文字体栈 + bg #f5f7fa；Element Plus 默认主题 + 顶部品牌色 VITE_TENANT_NAME

## 2. JWT 鉴权 + 登录 + 路由 guard（PR #2）✅

- [x] 2.1 api/client.ts axios + request 拦截器加 Authorization + response 401 → handleUnauthorized + router.push /login（带 redirect）
- [x] 2.2 stores/auth.ts Pinia + persist plugin（localStorage key=isales-auth）；login OAuth2PasswordRequestForm；JWT payload role 解析；logout 仅清状态（导航职责放调用方避免循环依赖）
- [x] 2.3 views/LoginView.vue 完整登录表单 + 校验 + loading + 错误提示（401 显示"账号或密码错误"）
- [x] 2.4 router beforeEach guard：未登录 → /login（带 redirect query）；已登录访问 /login → /dashboard
- [x] 2.5 DefaultLayout 顶栏接 auth store + 注销下拉
- [x] 2.6 3 个 vitest 测试：初始未登录 / JWT role 解码 / handleUnauthorized 清状态

## 3. 任务管理（Campaigns）— PR #3 minimal 已上线；9-tab 嵌套配置 DEFERRED

- [x] 3.1 api/campaigns.ts list / get / create / update / remove / start / pause
- [x] 3.2 stores/campaigns.ts Pinia + 乐观更新
- [x] 3.3 views/Campaigns/CampaignList.vue el-table + 启动/暂停/删除（popconfirm）+ 新建/编辑按钮
- [ ] 3.4 9 tab 嵌套配置编辑 — DEFERRED 到独立 PR（角色 / 裁判 / 润色 / 沉默 / 打断 / 转人工 / 收尾 / 时间窗口 / 重试 / 勿打 / 回调）
- [ ] 3.4-old el-tabs 分 9 个页签（详细列表保留作 follow-up reference）
  - 基础（name / voice_id / default_replies）
  - 角色配置（嵌套 role_config 子表 + 弹层编辑 prompt + 模型 + 温度）
  - 沉默激活（threshold / max / phrases / hangup_phrase）
  - 打断保护（whitelist / min_duration / max / strategy）
  - 转人工（4 种触发独立开关 + 阈值 + 衔接话术）
  - 收尾（max_rounds / max_seconds / closing_phrases / extraction_fields）
  - 时间窗口 + 节假日
  - 重试跟进（intervals / max_count / follow_up）
  - 勿打（do_not_call_keywords / do_not_call_llm_*）
  - 回调（嵌套 callback_config 子表）
- [ ] 3.5-3.8 嵌套 RoleConfig / FillerSet 弹层 + 校验 + 测试 — DEFERRED 到独立 PR

## 4. 线索管理（Leads）（PR #4）— minimal landed

- [x] 4.1 api/leads.ts CRUD + import multipart（5min timeout）
- [x] 4.2 stores/leads.ts list + 过滤参数（campaign_id / status）
- [x] 4.3 views/Leads/LeadList.vue el-table + 过滤栏 + status 颜色 tag 全枚举
- [ ] 4.4 LeadEditDialog（单条编辑）— DEFERRED
- [x] 4.5 LeadImportDialog el-upload + multipart import + 成功/失败明细 alert
- [ ] 4.6 测试 — DEFERRED

## 5. 音色 + 设备 + SIM 卡（PR #5）— minimal landed

- [x] 5.1 api/voice.ts list + preview（preview Web Audio 播放留 follow-up）
- [x] 5.2 views/VoiceModels/VoiceModelList.vue 列表
- [ ] 5.3 VoiceModelDialog 编辑 + 试听 — DEFERRED
- [x] 5.4 api/devices.ts + DeviceList 30s 轮询 + status 颜色 tag + unmount cleanup
- [x] 5.5 SimCardList ICCID / IMSI / 号码 / 余额 / 状态 tag
- [ ] 5.6 DeviceDetail device_sim_binding 历史 — DEFERRED
- [ ] 5.7 测试 — DEFERRED

## 6. 数据看板（Analytics）（PR #6）— minimal landed

- [x] 6.1 api/analytics.ts overview / byCampaign / timeseries
- [x] 6.2 Dashboard 4 StatCard + 2 echarts（接通率 7 日 line + 各任务 bar）
- [x] 6.3 echarts 按需 import（CanvasRenderer + LineChart + BarChart + Grid/Tooltip/Title/Legend）
- [ ] 6.4 时间筛选 / Campaign 切换 — DEFERRED
- [x] 6.5 接通率口径与 worker isales:metrics:7d 一致（前端不计算，仅展示后端字段）
- [ ] 6.6 测试 — DEFERRED

## 7. 通话监控（实时 WS）（PR #7）

- [ ] 7.1 `utils/wsClient.ts`：原生 WebSocket 包装类，自动重连（指数退避 200/500/1000/2000/4000ms 上限 4s）+ 30s 心跳 ping
- [ ] 7.2 `stores/monitoring.ts`：Map<call_record_id, CallSnapshot> reactive；WS event handler 按 EngineEvent.type 更新
- [ ] 7.3 `views/Monitor/MonitorView.vue`：路由 `/monitor/:campaign_id`；建 WS 到 /ws/calls/{id}?token=<jwt>；显示通话卡片网格（≤8 张活跃 + ≤8 张已结束）
- [ ] 7.4 `components/Monitor/CallCard.vue`：单卡片 — lead 信息 / 当前状态 / 当前 ASR partial（流式刷新）/ 最新 AI reply / 时长（秒级跳动）
- [ ] 7.5 通话结束后保留 5 分钟移出活跃区
- [ ] 7.6 EngineEvent.type 枚举完整 switch（status_changed / asr_partial / asr_final / transcript_appended / call_started / call_ended）；未知 type 控制台 warn
- [ ] 7.7 测试：wsClient 重连逻辑 / monitoring store 事件路由

## 8. 通话记录 + 详情（PR #8）

- [x] 8.1 api/calls.ts list + get
- [x] 8.2 CallList list + 详情按钮
- [x] 8.3 CallDetail 双栏（左 meta / 右 transcript timeline）；三栏 + pipeline_trace 折叠 — DEFERRED
- [x] 8.4 TranscriptTimeline el-timeline + event.type 着色 + ts 格式化 mm:ss；点击跳录音 — DEFERRED
- [x] 8.5 录音播放：el-descriptions 内嵌 HTML5 audio
- [ ] 8.6 PipelineTracePanel — DEFERRED
- [ ] 8.7 测试 — DEFERRED

## 9. 回调配置 + 回调记录（PR #9）— minimal landed

- [x] 9.1 api/callbacks.ts list（config + log）
- [x] 9.2 CallbackConfigList 列表（编辑器 alert 标注 follow-up）
- [ ] 9.3 CallbackConfigDialog（CodeMirror JsonLogic / Jinja2 编辑器）— DEFERRED
- [ ] 9.4 trigger dry-run — DEFERRED
- [x] 9.5 CallbackLogList list + 状态 / 重试 / HTTP / 错误列
- [ ] 9.6 CallbackLogDetail — DEFERRED
- [ ] 9.7 测试 — DEFERRED

## 10. 转人工任务 + 节假日（PR #10）— minimal landed

- [x] 10.1 HandoffTaskList list（v1 衰减实现 alert 标注）
- [x] 10.2 HolidayList list（CRUD 编辑 — DEFERRED）
- [ ] 10.3 PromptVersions — DEFERRED（CampaignEdit 嵌套配置一并）
- [ ] 10.4 ComingSoon 组件（PlaceholderView 已实施）
- [ ] 10.5 404 / 空状态 illustration / loading skeleton — DEFERRED

## 11. 部署 + 文档（PR #11）✅

- [x] 11.1 deploy/nginx.conf SPA fallback + /api 反代 + /ws WebSocket upgrade（proxy_read_timeout 3600s）+ gzip
- [x] 11.2 README 部署章节（已含 systemctl + journalctl + 部署步骤）
- [x] 11.3 .env.example
- [ ] 11.4 isales-api README 交叉引用 — DEFERRED（在主仓做）

## 12. 收尾（PR #12）— PARTIAL

- [x] 12.1 vitest 4/4 全绿 + vue-tsc 0 error；eslint 未配置 (CI 时再加)
- [ ] 12.2 端到端手工验收 — DEFERRED（需要 isales-api 部署 + 真路径联调）
- [ ] 12.3 monitor 页性能压测 — DEFERRED
- [ ] 12.4 浏览器兼容性测试 — DEFERRED
- [ ] 12.5 IMPLEMENTATION_PLAN 阶段 7 完成清单 — 路由全部点得通；嵌套配置 / CodeMirror 编辑器 / 真试听 / 性能 polish 留 follow-up
- [ ] 12.6 archive — 等用户决定（功能页 minimal 已就位，深度 polish 留独立 change）
