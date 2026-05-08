## Why

阶段 1-5 已经把后端全套跑通：isales-common（v0.1.2 模型 / Provider ABC）/ isales-api（CRUD + WS + 鉴权）/ isales-scheduler / isales-engine（状态机 + 三层管线 + mock & real Provider）/ isales-worker（异步后处理）。但目前**所有运维 / 业务操作都得直连 DB 或调 API curl**——非工程师无法操作系统、看不到通话过程、查不了数据。本 change 实施 IMPLEMENTATION_PLAN.md 阶段 7 的 isales-web（Vue 3 前端），让"建任务 → 导线索 → 启动 → 看监控 → 看记录"完整流程在浏览器里走通。

按 IMPLEMENTATION_PLAN.md 阶段 7 + impl-api 已交付的 endpoints + service-communication spec § "API ↔ 前端 WebSocket 代理" 实施。前端独立仓库 `isales-web`（Vue 3 + Vite + Element Plus + Pinia + Vue Router），通过 isales-api 的 HTTP / WS endpoints 操作所有数据，不直连 DB。

## What Changes

- **isales-web 仓库新建**（独立 git，前端不属于 Python monorepo）
  - 仓库骨架：`package.json` (npm)、Vite 配置、TypeScript / Vue 3 setup、ESLint + Prettier、CI（vitest + lint）
  - 路由层：Vue Router 4，路由结构按页面划分（详见 design.md），路由 guard 检查 JWT
  - 状态管理：Pinia，per-domain stores（auth / campaigns / leads / calls / agents / monitoring）
  - HTTP 客户端：axios，统一 baseURL（`VITE_API_BASE`）+ 请求拦截器自动加 `Authorization: Bearer <jwt>`；401 自动跳登录
  - WebSocket 客户端：原生 WebSocket，`/ws/calls/{campaign_id}?token=<jwt>`，自动重连（指数退避，3 次失败放弃）

- **JWT 鉴权 + 登录页**（按 isales-api `/auth/login` 已发布的 endpoint）
  - 登录页：用户名 + 密码 → POST /auth/login → 拿 JWT → Pinia auth store 存 token + 用户信息（localStorage 持久化）
  - 路由 guard：未登录跳 /login；token 过期 → 401 → 跳 /login + 清 localStorage
  - 注销按钮：清 token + 跳登录

- **任务管理页（Campaigns）**
  - 列表：`/campaigns`（GET /campaigns），表格列：name / 状态 / lead 总数 / 接通率（接 /analytics）/ 操作
  - 操作：新建 / 编辑 / 启动（POST /campaigns/{id}/start）/ 暂停 / 删除
  - 编辑页：`/campaigns/:id/edit`，表单覆盖全部 Campaign 字段（按 isales-common Campaign 模型 80+ 字段，分 Tab：基础 / 角色配置 / 沉默激活 / 打断保护 / 转人工 / 收尾 / 回调 / 时间窗口 / 重试跟进 / 勿打）
  - 嵌套配置：role_config 列表（角色 / 裁判 / 润色三类）+ filler_set 列表 + callback_config 列表 — 都用子表格 + 弹层编辑

- **线索管理页（Leads）**
  - 列表：`/leads`（GET /leads，按 campaign_id / status 过滤），表格列：name / phone / 状态 / 重试次数 / 跟进次数 / next_call_at / 操作
  - CSV 导入：`/leads/import` 弹层选 campaign + 上传 CSV → POST /leads/import（multipart）→ 显示成功/失败明细
  - 单条编辑：弹层修改 phone / name / custom_data / status

- **音色管理页（Voice Models）**
  - 列表：`/voice-models`，表格列：name / vendor / voice_id / 操作
  - 新增 / 编辑：弹层选 vendor + 输入 voice_id + 取个名
  - 试听：调用 GET /voice-models/{id}/preview 拿 PCM bytes → 浏览器 Web Audio API 播放（输入文本可选）

- **设备管理页（Devices + SIM 卡）**
  - 列表：`/devices`（GET /devices），表格列：型号 / IMEI / 状态 / 当前 SIM / 信号 / 接通率
  - 状态实时刷新：每 30s 轮询 GET /devices（v1 简化；v2 走 WS）
  - SIM 卡子页：`/sim-cards`（GET /sim-cards），列：ICCID / IMSI / phone_number / 余额 / 套餐
  - 设备-SIM 绑定历史：详情页里看 device_sim_binding 表

- **数据看板（Analytics）**
  - 路由：`/dashboard`，按 Campaign 切换或聚合
  - 卡片：今日接通率 / 目标达成率 / 平均通话时长 / 在打通话数（实时）
  - 图表：echarts，按时间分布（接通率 7 日趋势 / 通话时长直方图 / 目标达成漏斗）
  - 数据来源：GET /analytics/* + Redis isales:metrics:7d:{campaign_id}（worker 写入；通过 isales-api 转发暴露）

- **通话监控（实时 WS）**
  - 路由：`/monitor/:campaign_id`，订阅 `/ws/calls/{campaign_id}?token=<jwt>`
  - UI：通话卡片列表（每张卡片一通在打通话），显示状态 / lead / 当前 ASR partial 文本 / AI 当前 reply
  - 卡片实时更新：WS 推 EngineEvent → Pinia monitoring store → reactive 刷新
  - 历史回放：通话结束后卡片移到"已结束"区，5 分钟后自动清

- **通话记录（Call Records）**
  - 列表：`/calls`（GET /calls，按 campaign / lead / 时间过滤），表格列：lead / phone / 通话时长 / hangup_cause / goal_achieved / 操作
  - 详情页：`/calls/:id`
    - transcript 时间轴渲染（greeting / user_speech / ai_reply / filler / silence_activation / interruption / transfer / hangup 各事件不同样式）
    - 录音回放（如果 recording_url 非 null，audio 元素播放，根据 transcript ts 跳转）
    - 提取字段（call_summary.extracted_fields）展示
    - pipeline_trace 折叠面板（高级用户看候选 / 裁判 / 润色细节）

- **回调配置页（Callback Configs）**
  - 列表：`/callback-configs`（GET /callback-configs），表格列：name / trigger / url / status / 操作
  - 新增 / 编辑：弹层 — trigger（JsonLogic 文本编辑器 + validate 按钮）/ payload_template（Jinja2 文本编辑器）/ url / signing_secret / retry_policy
  - 触发记录子页：`/callback-logs/:config_id` 看 callback_log 表（GET /callback-logs?config_id=...）

- **测试**
  - vitest 单测：组件 props / events / store actions / 路由 guard / API 客户端拦截器
  - Playwright e2e（可选 v2）：登录 → 创建 campaign → 导入 lead → 启动 → 看监控 → 看记录全流程
  - 本 change 仅做 vitest；e2e 留 v2

- **部署**
  - `npm run build` 产物 dist/ 静态文件
  - Nginx 配置：dist/ 前面挂个 nginx，/api 反代到 isales-api，/ws 反代 isales-api（WebSocket upgrade）
  - `deploy/nginx.conf` + `deploy/isales-web.service`（如果用 systemd 跑 nginx 容器；裸 nginx 不需要 service）

## Capabilities

### New Capabilities

无新 capability — 前端是已有 capability（service-communication / data-model / 各业务 spec）的 UI 层。

### Modified Capabilities

- `service-communication`: 修改 Requirement "API ↔ 前端 WebSocket 代理"——把"前端订阅 WebSocket 后的协议演进"从隐式约定提升为硬契约：前端 SHALL 通过 `EngineEvent` discriminated union 解析 WS 消息（按 message-contract spec），MUST NOT 假定字段命名或类型；新事件类型 MUST 通过 OpenSpec change 加入 union 后前端再处理（避免前端裸用未知 type 字符串导致破坏性升级）。

其余对各业务 spec（data-model / retry-followup / time-window 等）是前端 UI 层的**首次实施**，不修改其 requirement。

## Impact

- **新仓库**：`isales-web`（独立 git repo；前端栈，与 Python 后端解耦）
- **isales-api 依赖**：v0.1.0（已部署），endpoints 全部就位；本 change 不需要 isales-api 改
- **依赖链**：本 change 完成后 v1 完成标准 #4 达成（"后台 UI 能完成全部管理操作，不需要直接改 DB"）
- **可独立实施**：纯前端，不阻塞任何后端工作；可分阶段灰度（先发任务 / 线索 / 设备三个最常用页面，监控 / 记录 / 看板后续 PR 跟进）
- **不影响**：所有 Python 服务零改动；isales-common / api / engine / scheduler / worker / telephony 不动
- **新环境变量**（前端）：`VITE_API_BASE`（默认 `/api`）、`VITE_WS_BASE`（默认 `/ws`）、`VITE_TENANT_NAME`（顶部品牌名，默认 "iSales 智能外呼"）
- **新依赖**：vue@3 / vite / element-plus / pinia / vue-router / axios / echarts / dayjs / @vueuse/core / vitest / @testing-library/vue
- **超出本 change 范围**：Playwright e2e 测试（v2）；移动端响应式（v2 仅做桌面 1280+）；i18n（v2 仅中文）；细粒度权限（v1 仅 admin 角色）；多租户（v1 单租户）；离线缓存（不需要）；自定义主题（用 Element Plus 默认）
