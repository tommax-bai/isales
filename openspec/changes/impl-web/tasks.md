> 实施在 isales-web 仓库（新建）。每组对应 1~2 个 PR，按顺序合入。
> 前端独立栈：Vue 3 + Vite + TypeScript + Element Plus + Pinia + Vue Router + axios + echarts + vitest。
> 不动后端任何 Python 服务（API endpoints 已就位）。

## 1. isales-web 仓库骨架（PR #1）

- [ ] 1.1 `git init isales-web` + `.gitignore`（node_modules / dist / .env.local）
- [ ] 1.2 `package.json`（npm；deps: vue@^3.4 / vite@^5 / element-plus@^2 / pinia@^2 / vue-router@^4 / axios / echarts + vue-echarts / dayjs / @vueuse/core）
- [ ] 1.3 dev deps: typescript / @vue/tsconfig / vue-tsc / eslint + @vue/eslint-config-typescript / prettier / vitest + @vue/test-utils + jsdom / @testing-library/vue
- [ ] 1.4 `vite.config.ts`：vue plugin / Element Plus auto import / path alias `@/` → `src/` / proxy `/api` → `http://localhost:8000` / proxy `/ws` → `ws://localhost:8000`（dev）
- [ ] 1.5 `tsconfig.json` + `tsconfig.node.json`（vite Vue 3 推荐）
- [ ] 1.6 目录骨架：`src/{main.ts,App.vue,router,stores,api,components,views,types,utils,assets}/`、`tests/`、`deploy/`
- [ ] 1.7 README + CI（`.github/workflows/ci.yml`：npm install + lint + vue-tsc --noEmit + vitest）
- [ ] 1.8 base layout：`<App>` → router-view；登录之外的所有页面用 `<DefaultLayout>`（侧边栏 + 顶栏）
- [ ] 1.9 主题：仅 Element Plus 默认 + 全局 reset.css + 顶部品牌色（VITE_TENANT_NAME）

## 2. JWT 鉴权 + 登录 + 路由 guard（PR #2）

- [ ] 2.1 `api/client.ts`：axios.create({baseURL: VITE_API_BASE})；request 拦截器加 Authorization；response 401 → router.push('/login') + 清 auth store
- [ ] 2.2 `stores/auth.ts`：Pinia auth store — token / user / isAuthenticated computed；login(creds) → POST /auth/login → 存 token；logout() → 清；持久化 token 到 localStorage
- [ ] 2.3 `views/LoginView.vue`：用户名 + 密码表单 + 调 auth.login + 错误提示
- [ ] 2.4 `router/index.ts`：路由表 + beforeEach guard（未登录跳 /login；已登录访问 /login 跳 /dashboard）
- [ ] 2.5 `components/Layout/DefaultLayout.vue`：侧边栏导航（按角色权限渲染；v1 admin 全显示）+ 顶栏（用户名 + 注销按钮）
- [ ] 2.6 测试（vitest）：auth store login 成功 / 401 失败；router guard 未登录跳转

## 3. 任务管理（Campaigns）（PR #3）

- [ ] 3.1 `api/campaigns.ts`：CRUD + start/pause + status query
- [ ] 3.2 `stores/campaigns.ts`：Pinia store，list / current / loading
- [ ] 3.3 `views/Campaigns/CampaignList.vue`：el-table + 状态 / 接通率列；操作列含编辑 / 启动 / 暂停 / 删除
- [ ] 3.4 `views/Campaigns/CampaignEdit.vue`：el-tabs 分 9 个页签
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
- [ ] 3.5 `components/Campaign/RoleConfigDialog.vue`：弹层编辑 role_config（kind / model / temperature / top_p / prompt content）
- [ ] 3.6 `components/Campaign/FillerSetDialog.vue`：弹层编辑 filler_set + filler_phrase 子表
- [ ] 3.7 表单校验（element form rules）+ 提交后跳列表 + 成功提示
- [ ] 3.8 测试：campaigns store CRUD action / 启停 action

## 4. 线索管理（Leads）（PR #4）

- [ ] 4.1 `api/leads.ts`：list / create / update / delete / import
- [ ] 4.2 `stores/leads.ts`：列表 + 过滤参数（campaign_id / status / search）
- [ ] 4.3 `views/Leads/LeadList.vue`：el-table + 过滤栏 + 分页（默认 50/页）
- [ ] 4.4 `views/Leads/LeadEditDialog.vue`：弹层编辑 phone / name / custom_data（key-value 列表 UI）/ status
- [ ] 4.5 `views/Leads/LeadImportDialog.vue`：选 campaign + el-upload 拖拽 CSV → POST multipart → 进度 + 成功/失败明细表
- [ ] 4.6 测试：leads store list 过滤 / import 错误响应解析

## 5. 音色 + 设备 + SIM 卡（PR #5）

- [ ] 5.1 `api/voiceModels.ts`：CRUD + preview
- [ ] 5.2 `views/VoiceModels/VoiceModelList.vue`：列表 + 试听按钮（点击 → fetch /voice-models/{id}/preview → Web Audio API 播放 PCM）
- [ ] 5.3 `views/VoiceModels/VoiceModelDialog.vue`：弹层编辑（vendor / voice_id / name / 测试文本）
- [ ] 5.4 `api/devices.ts` + `views/Devices/DeviceList.vue`：列表 + 状态 / IMEI / 当前 SIM；30s 轮询刷新；状态颜色（idle 绿 / dialing 蓝 / in_call 蓝 / flagged 红 / offline 灰）
- [ ] 5.5 `views/SimCards/SimCardList.vue`：ICCID / IMSI / phone_number / 余额；操作含编辑 / 弃用
- [ ] 5.6 `views/Devices/DeviceDetail.vue`：单设备页含 device_sim_binding 历史子表
- [ ] 5.7 测试：voice preview 调用 / device 轮询 cleanup（unmount 不再轮询）

## 6. 数据看板（Analytics）（PR #6）

- [ ] 6.1 `api/analytics.ts`：GET /analytics/overview / /analytics/by_campaign / /analytics/timeseries
- [ ] 6.2 `views/Dashboard.vue`：4 卡片（今日接通率 / 目标达成率 / 平均通话时长 / 在打通话数）+ 3 图表（接通率 7 日趋势 / 通话时长直方图 / 目标达成漏斗）
- [ ] 6.3 vue-echarts 按需 import（避免 echarts 全量打包）
- [ ] 6.4 时间筛选 / Campaign 切换
- [ ] 6.5 接通率定义口径与 worker isales:metrics:7d Hash 一致（answered / total）
- [ ] 6.6 测试：analytics store 数据加载 + 图表 props 计算

## 7. 通话监控（实时 WS）（PR #7）

- [ ] 7.1 `utils/wsClient.ts`：原生 WebSocket 包装类，自动重连（指数退避 200/500/1000/2000/4000ms 上限 4s）+ 30s 心跳 ping
- [ ] 7.2 `stores/monitoring.ts`：Map<call_record_id, CallSnapshot> reactive；WS event handler 按 EngineEvent.type 更新
- [ ] 7.3 `views/Monitor/MonitorView.vue`：路由 `/monitor/:campaign_id`；建 WS 到 /ws/calls/{id}?token=<jwt>；显示通话卡片网格（≤8 张活跃 + ≤8 张已结束）
- [ ] 7.4 `components/Monitor/CallCard.vue`：单卡片 — lead 信息 / 当前状态 / 当前 ASR partial（流式刷新）/ 最新 AI reply / 时长（秒级跳动）
- [ ] 7.5 通话结束后保留 5 分钟移出活跃区
- [ ] 7.6 EngineEvent.type 枚举完整 switch（status_changed / asr_partial / asr_final / transcript_appended / call_started / call_ended）；未知 type 控制台 warn
- [ ] 7.7 测试：wsClient 重连逻辑 / monitoring store 事件路由

## 8. 通话记录 + 详情（PR #8）

- [ ] 8.1 `api/calls.ts`：list（按 campaign / lead / time_range / hangup_cause）+ get / get_trace
- [ ] 8.2 `views/Calls/CallList.vue`：列表 + 过滤栏 + 分页
- [ ] 8.3 `views/Calls/CallDetail.vue`：路由 `/calls/:id`，三栏布局
  - 左：lead 信息 + call meta（开始 / 结束 / 时长 / hangup_cause / transfer_status）
  - 中：transcript 时间轴 + 录音播放器
  - 右：提取字段 + pipeline_trace 折叠面板
- [ ] 8.4 `components/Calls/TranscriptTimeline.vue`：自研，按 event.type 渲染不同 icon + 颜色 + 内容
  - greeting / ai_reply 蓝色对话气泡（左对齐）
  - user_speech 灰色对话气泡（右对齐）
  - filler / silence_activation 浅灰 inline 标签
  - interruption / transfer_initiated / transfer_marked / hangup 红 / 黄 milestone marker
  - default_reply_used / state_error 警告色
  - 点击事件跳转录音对应 ts
- [ ] 8.5 `components/Calls/RecordingPlayer.vue`：HTML5 audio + 时间戳跳转 API
- [ ] 8.6 `components/Calls/PipelineTracePanel.vue`：按 turn_id 折叠面板，展开时延迟 GET /calls/{id}/trace；展示候选 / 裁判结果 / 润色输入输出
- [ ] 8.7 测试：transcript timeline event-type → icon 映射 / pipeline trace lazy-load

## 9. 回调配置 + 回调记录（PR #9）

- [ ] 9.1 `api/callbackConfigs.ts` + `api/callbackLogs.ts`：CRUD + log query
- [ ] 9.2 `views/CallbackConfigs/CallbackConfigList.vue`：列表 + 测试触发按钮（POST /callback-configs/{id}/test）
- [ ] 9.3 `views/CallbackConfigs/CallbackConfigDialog.vue`：name / url / method / trigger（CodeMirror JsonLogic）/ payload_template（CodeMirror Jinja2）/ signing_secret（密文掩码 + 重新生成按钮 v2）/ retry_policy / timeout
- [ ] 9.4 trigger validate 按钮：本地 JsonLogic eval（占位 ctx）+ 后端 dry-run（POST /callback-configs/validate）
- [ ] 9.5 `views/CallbackLogs/CallbackLogList.vue`：按 config_id / status 过滤 / 分页
- [ ] 9.6 `views/CallbackLogs/CallbackLogDetail.vue`：单条详情（trigger 命中证据 / payload 渲染结果 / HTTP 请求响应 / 重试历史）
- [ ] 9.7 测试：CodeMirror 编辑器组件包装 / signing_secret 掩码逻辑

## 10. 转人工任务 + 节假日 + 收尾页面（PR #10）

- [ ] 10.1 `views/HandoffTasks/HandoffTaskList.vue`（GET /handoff-tasks）：v1 仅展示 — call_record / agent_id / trigger_type / created_at；不做"领取/完成"按钮（v2）
- [ ] 10.2 `views/Holidays/HolidayList.vue`（GET/POST/DELETE /holidays）：日期 / name CRUD
- [ ] 10.3 `views/PromptVersions/`：v1 仅显示 role_config 当前 prompt（已在 CampaignEdit 中），不做历史版本 UI（v2）
- [ ] 10.4 全站「未实现」占位的 page（如多租户切换、设置）添加 ComingSoon 组件
- [ ] 10.5 主题 / 全局 layout 收尾（404 页 / 空状态 illustration / loading skeleton）

## 11. 部署 + 文档（PR #11）

- [ ] 11.1 `deploy/nginx.conf`：location / try_files SPA fallback；location /api 反代 isales-api 8000；location /ws 反代 + WebSocket upgrade headers + proxy_read_timeout 3600s
- [ ] 11.2 README 部署章节：build → scp dist → nginx 配置 → reload
- [ ] 11.3 `.env.example`（VITE_API_BASE / VITE_WS_BASE / VITE_TENANT_NAME）
- [ ] 11.4 isales-api impl-api 阶段 2B README 加"前端反代"章节交叉引用

## 12. 收尾

- [ ] 12.1 vitest 全绿 + vue-tsc 0 error + eslint 0 warning
- [ ] 12.2 端到端手工验收（5 分钟）：登录 → 建 campaign → 导 lead → 看监控 → 看记录全流程
- [ ] 12.3 性能：monitor 页 8 路并发模拟 500ms 一次 partial × 30 秒 → 浏览器 CPU < 30%
- [ ] 12.4 浏览器兼容：Chrome / Edge / Firefox 最新两版（v1 不支持 Safari 老版本）
- [ ] 12.5 IMPLEMENTATION_PLAN.md 阶段 7 验收清单全部勾选
- [ ] 12.6 主仓 commit 标记 impl-web 实施完成；archive 由 /opsx:archive 触发
