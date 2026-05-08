## Context

阶段 7 的 isales-web 前端实施。后端 API + WebSocket 全部就位（impl-api 阶段 2B 已交付 / 归档）；本 change 把 v1 完成标准 #4（"后台 UI 能完成全部管理操作"）做掉。

约束：
- Vue 3 (Composition API + `<script setup>`) — IMPLEMENTATION_PLAN 已锁定
- Vite 作为构建工具
- Element Plus 作为 UI 组件库（中文场景适配 + 完整组件集 + Element 团队维护）
- Pinia 作为状态管理（Vue 3 官方推荐，比 Vuex 更轻）
- Vue Router 4
- TypeScript 全栈（强类型 → 与后端 Pydantic 模型对齐时少踩坑）
- 桌面优先（1280+ 宽度）；不做移动端响应式
- 仅中文（不做 i18n）
- v1 单租户、单角色（admin），不做权限粒度

## Goals / Non-Goals

**Goals:**

- 登录 + JWT 鉴权 + 路由 guard
- 任务（Campaign）全套 CRUD：基础信息 + 嵌套配置（角色 / 裁判 / 润色 / 垫词 / 回调 / 时间窗口 / 重试 / 勿打 / 沉默 / 打断保护 / 收尾 / 转人工）
- 线索（Lead）CRUD + CSV 导入
- 音色（VoiceModel）CRUD + 试听
- 设备（Device）+ SIM 卡列表 + 状态轮询
- 数据看板（Analytics）：卡片 + echarts 图表
- 通话监控（实时 WebSocket）：在打通话卡片 + ASR partial / AI reply 实时刷新
- 通话记录列表 + 详情（transcript 时间轴 + 录音回放 + 提取字段 + pipeline_trace 折叠）
- 回调配置 CRUD + JsonLogic / Jinja2 编辑器
- 部署：Vite build → 静态文件，Nginx 反代 API + WS
- vitest 单测覆盖 store / 路由 guard / 关键组件

**Non-Goals:**

- Playwright e2e（v2）
- 移动端响应式（v2）
- i18n / 多语言（v2）
- 细粒度权限（v1 admin 一种角色）
- 多租户（v1 单租户）
- 自定义主题 / 暗色模式（用 Element Plus 默认）
- 服务端渲染（SPA 即可）
- PWA / 离线（不需要）
- handoff_task 坐席工作流（v1 通过 GET /handoff-tasks 列表呈现，不做"领取/完成"按钮 — 因为 v1 转人工是衰减实现，坐席通过其他系统实际外呼）
- prompt_version 历史 diff UI（v1 仅显示当前版本；版本管理留 v2）

## Decisions

### 1. 不引入 SSR 框架（Nuxt / Quasar），用 Vite SPA

- **选择**：Vite + Vue 3 + 静态构建产物；Nginx 服务 SPA + 反代 /api + /ws
- **理由**：
  - 后台管理系统不需要 SEO，SPA 足够
  - SSR 引入 Node 服务，部署多一层
  - Vite 快速 HMR 开发体验好
- **替代**：Nuxt → SSR 增加复杂度；CRA → React 生态切换不必要

### 2. UI 库选 Element Plus 而非 Naive UI / Ant Design Vue

- **选择**：Element Plus
- **理由**：
  - Element 团队主维护，组件生态全（Table / Form / Dialog / Tabs / Cascader / DatePicker / Tree 等都齐）
  - 中文场景适配最好（搜索 / 排序 / 验证消息）
  - 与 Vue 3 ts 友好
- **替代**：Naive UI → 较新，社区小；Ant Design Vue → 风格偏 Ant 不一定贴中国 SaaS

### 3. 状态管理：Pinia（不用 composables 裸管）

- **选择**：Pinia stores per domain（auth / campaigns / leads / calls / devices / monitoring）
- **理由**：
  - 跨页面共享状态（如 auth token / current campaign）需要持久层
  - Pinia DevTools 调试好
  - 持久化用 `pinia-plugin-persistedstate` 把 auth token 存 localStorage
- **替代**：纯 composables → 跨组件分享 ref 容易 stale

### 4. HTTP 客户端：axios 配实例 + 拦截器

- **选择**：单 `apiClient = axios.create({baseURL: VITE_API_BASE})`；request 拦截器加 Authorization 头；response 拦截器 401 → router.push('/login')
- **理由**：
  - 拦截器统一处理 token 刷新 / 错误码
  - axios 错误对象有 response.data，方便从后端 Pydantic ValidationError 解析具体字段错误
- **替代**：fetch 裸用 → 错误处理重复；ky → 引入新依赖收益小

### 5. WebSocket：原生 WS + 重连 + 心跳

- **选择**：每个监控页打开时建一条 WS 到 `/ws/calls/{campaign_id}?token=<jwt>`；离开页面 close；30s 心跳防中间代理断；连接断开后指数退避重连（200ms / 500ms / 1s / 2s / 4s）
- **理由**：
  - service-communication spec 明确 WS endpoint shape
  - SockJS / socket.io 客户端引入额外协议层无收益
- **替代**：所有页面共享一条 WS → 复杂；SockJS → 多了 polling 兜底，但 Nginx 直接反代 WS 已经稳定

### 6. echarts vs ApexCharts vs Chart.js

- **选择**：echarts（通过 vue-echarts 封装）
- **理由**：
  - 中国本土最常用，文档多
  - 看板要的趋势 / 漏斗 / 直方图 echarts 都直接支持
- **替代**：ApexCharts → 偏国际化；Chart.js → 灵活度低

### 7. transcript 时间轴：自研 + Element Plus Timeline

- **选择**：自研 `<TranscriptTimeline>` 组件，按 transcript event type 渲染不同 icon + 颜色 + 内容；用 Element Plus 的 Timeline 组件做底层骨架
- **理由**：
  - transcript spec 事件类型枚举固定，自研可严格 type-check
  - Element Plus Timeline 提供基础布局 + 自定义 dot
- **替代**：原生 div + flex → 重复造轮子；vis.js timeline → 太重

### 8. JsonLogic / Jinja2 编辑器：CodeMirror 6

- **选择**：CodeMirror 6 + JSON 模式（JsonLogic）+ Jinja2 自定义高亮
- **理由**：
  - 比纯 textarea 体验好（语法高亮 + 括号配对）
  - 比 Monaco 轻量（Monaco 是 IDE 级，过重）
- **替代**：纯 textarea → 不友好；Monaco → 加载慢

### 9. CSV 上传：用 Element Plus Upload + 后端 multipart

- **选择**：`<el-upload>` POST multipart 到 /leads/import；后端返回 success / failure 明细 → 前端展示
- **理由**：Element 组件成熟；前端不预解析 CSV（后端责任）
- **替代**：前端解析 CSV → 大文件浏览器卡

### 10. 路由结构

- 顶层布局 `/`（侧边栏 + 顶栏 + main outlet）
- 登录 `/login`（布局外）
- 子路由：
  - `/dashboard` 数据看板
  - `/campaigns` 任务列表
  - `/campaigns/new` 新建（reuse edit 表单）
  - `/campaigns/:id/edit` 编辑（含嵌套配置 Tab）
  - `/leads` 线索列表
  - `/voice-models` 音色
  - `/devices` 设备
  - `/sim-cards` SIM 卡
  - `/monitor` 通话监控（默认所有 active campaign）
  - `/monitor/:campaign_id` 单 campaign 监控
  - `/calls` 通话记录列表
  - `/calls/:id` 详情
  - `/callback-configs` 回调配置
  - `/callback-logs` 回调记录（按 config_id 过滤）
  - `/handoff-tasks` 转人工任务（v1 仅展示，不做坐席领取）
  - `/holidays` 节假日（time-window 用）

### 11. TypeScript 类型与后端 Pydantic 对齐

- **选择**：在 `src/types/` 手写 TypeScript interface 镜像 isales-common Pydantic 模型；不自动生成（v1 模型相对稳定）
- **理由**：
  - openapi-typescript 自动生成会因 isales-api OpenAPI schema 边界 case 失败
  - v1 30 个左右模型，手写 1 天可完成
- **替代**：openapi-typescript-codegen → 自动但维护期 bug 多

### 12. 不实现 prompt_version 历史 diff

- **选择**：v1 编辑 role_config.prompt 时直接保存到 current_prompt_version_id 指向的 PromptVersion 表（API 已实现"创建新版本"行为）；前端只显示当前版本，不展示历史
- **理由**：v1 用户少（admin 一两人），改 prompt 不频繁；版本回滚 v2 加
- **替代**：完整 diff UI → 重，v1 不需要

### 13. 部署：Nginx 单进程同主机反代

- **选择**：`nginx -g 'daemon off;'` 容器 / 系统服务运行；root 指向 dist/；location /api → isales-api 8000；location /ws → isales-api 8000 + WebSocket upgrade
- **理由**：
  - v1 单主机部署，前后端同机
  - Nginx 处理 SPA fallback (try_files $uri $uri/ /index.html)
- **替代**：CDN + 跨域 → 引入 CORS 复杂度；前端独立服务（Node serve / caddy）→ 多一层

### 14. 监控页 UI：实时刷新但不爆 DOM

- **选择**：监控页最多展示 8 张卡片（v1 ≤8 路并发，刚好对应）；超过 8 路时新通话挤掉最早进入 wrap_up 的；通话结束后保留 5 分钟可见再清
- **理由**：v1 并发上限 8 路；DOM 节点控制在 ≤16 张卡片范围
- **替代**：虚拟滚动 → 当前规模不需要

## Risks / Trade-offs

| 风险 | 缓解 |
|---|---|
| Element Plus 中文文档但英文 issue tracker 响应慢 | v1 用稳定版 v2.x；遇到 bug 优先 stack overflow / 中文社区 |
| WS 经 Nginx 反代时连接超时（默认 60s 关连接） | nginx.conf 加 `proxy_read_timeout 3600s`；前端 30s 心跳 |
| Campaign 80+ 字段表单膨胀 → 用户填错率高 | 分 Tab + 必填高亮 + 默认值合理 + 字段帮助文本 |
| 后端 Pydantic ValidationError 字段路径前端难展示 | axios response 拦截器解析 422 errors → 把 `loc: ["body", "x", "y"]` 翻译成中文路径 + Element Form errors prop |
| 通话监控 WS 消息高频（每 200ms partial）→ Vue reactive 卡 | partial 用 ref 直接覆盖（不 array push），避免 reactive 大对象重建 |
| transcript 时间轴上百个事件渲染慢 | 折叠 system 事件（filler / state_changed），默认只显示 user_speech + ai_reply + 关键 milestone |
| CSV 大文件（10 万 lead）后端处理超时 → 前端 axios 默认 timeout 触发 | 前端 import 接口 timeout 设 5 分钟；后端 isales-api impl-api 已有分批处理 |
| 录音回放跨域：audio src 直接指向 OSS URL → CORS 阻断 | OSS 配 CORS 允许前端 origin；fallback：通过 isales-api 代理 GET /calls/{id}/recording → stream |
| 设备状态 30s 轮询太慢 → 故障感知延迟 | v1 接受；v2 走 WS 推 device_status_changed 事件 |
| Pinia store 持久化 token 到 localStorage 风险 XSS | v1 接受（admin 内网用）；v2 加 CSP + httponly cookie |
| 看板 echarts 加载慢（核心 echarts 包 ~900KB） | echarts 按需引入（只 import 用到的图表类型）；vite split chunk |
| pipeline_trace JSONB 巨大（每轮几 KB）→ 详情页加载慢 | API 端 /calls/{id} 默认不返回 pipeline_trace；前端按需 GET /calls/{id}/trace 展开折叠时再请求 |

## Migration Plan

不适用——新仓库 + 首次部署，无运行时迁移。

部署：

1. `cd isales-web && npm install && npm run build`（产 dist/）
2. 拷 `dist/` 到目标主机 `/var/www/isales-web/`
3. 拷 `deploy/nginx.conf` 到 `/etc/nginx/sites-available/isales-web` + symlink + reload
4. 浏览器访问 `https://your-domain/login`

无运行时回滚——前端版本回滚 = 拷旧 dist/ 重 reload nginx。

## Open Questions

- 数据看板的图表"今日"是按 UTC 还是 Asia/Shanghai：默认 Asia/Shanghai（与 scheduler / api 共享 TZ env）
- 通话监控页的"通话结束后保留 5 分钟"是 5 分钟还是按用户偏好：v1 硬编码 5 分钟，v2 加用户配置
- 设备故障告警是否要在前端弹窗 push：v1 不做（依赖 Prometheus / 钉钉外发）；v2 候选
- prompt_version 编辑保存时如果已有该 role_config 的 PromptVersion 引用了这个 content：API 端会复用还是新建？取决于 isales-api 实现，前端不关心，调用方式都一样
- handoff_task 是否要前端"完成"按钮：v1 不做（spec § 坐席工作流是 v2 候选）；v1 仅展示
- callback_log 列表分页：v1 默认 50/页，前端不实现自定义分页大小（v2）
- 接通率定义：worker 写 isales:metrics:7d:{campaign_id} Hash 时 answered = hangup_cause ∈ {normal_clearing / wrap_up_completed / silence_max_reached / user_hangup}；前端展示 = answered / total_calls；接通率统计口径与 worker 保持一致
- 录音回放是否要支持倍速：v1 不做（HTML5 audio 默认 1x）；v2 加 0.5x / 1.5x / 2x
- 多 campaign 同时监控：v1 一次只看一个 campaign（路由参数）；v2 候选 dashboard 看所有
- callback signing_secret 编辑：v1 仅可写不可读（密文存 DB，前端创建后 GET 时仅返回掩码 ****）；v2 加"重新生成"按钮
