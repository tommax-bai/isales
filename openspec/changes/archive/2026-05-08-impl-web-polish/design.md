## Context

stage 7 impl-web 已 archive，13 个路由 minimal 上线但 32 个 task 标 DEFERRED。本 change 把 deferred 收口，重点是 Campaign 9-tab 嵌套配置（v1 真跑必需）+ 回调 CodeMirror 编辑器（运营配 webhook 必需），其余按价值排序顺手做掉。

约束：
- Vue 3.5 + Vite 5 + TypeScript（impl-web 已锁定）
- Element Plus 默认主题（不做自定义）
- 不动后端任何 Python 服务
- isales-api 已部署的 endpoints 主要是 RESTful 全套；本 change 假定后端就绪，遇到缺失 endpoint 标 follow-up（不阻塞前端）

## Goals / Non-Goals

**Goals:**

- Campaign 9-tab 完整编辑（基础 / 角色 / 沉默 / 打断 / 转人工 / 收尾 / 时间窗口 / 重试 / 勿打 / 回调）覆盖 isales-common Campaign 全部 80+ 字段 + 嵌套子表（role_config / filler_set / filler_phrase / callback_config）
- CodeMirror 6 JsonLogic（JSON mode）+ Jinja2（HTML mode + 自定义高亮）薄包装组件 `<CodeEditor>`
- CallbackConfigEdit 真表单（trigger / payload / url / signing_secret 掩码 + dry-run validate 按钮）
- Lead 单条编辑 dialog + custom_data 动态 KV
- 音色试听 Web Audio API（8kHz mono 16-bit LE PCM 直构 AudioBuffer）
- pipeline_trace 折叠面板（CallDetail 右侧）+ lazy GET trace
- echarts manualChunks 拆 chunk（DashboardView < 200KB）
- 404 页 + loading skeleton + empty-state 三类 UI 体验补
- ESLint + Prettier + GitHub Actions CI（lint + typecheck + test + build）
- vitest 单测从 4 → 25+
- Lead 列表分页（el-pagination + total）

**Non-Goals:**

- Playwright e2e（独立 v2 change）
- 移动端响应式（v2）
- i18n / 多语言（v2）
- 暗色模式（v2）
- 多租户切换（v2）
- 客户端 JsonLogic eval（v1 仅语法校验 + 后端 dry-run）
- prompt_version 历史 diff（v2）
- 设备 / 通话状态从轮询切 WS push 的服务端配套（依赖后端 spec 演进）
- 录音回放倍速 / 跳转录音的 ts 同步（v2）
- callback_log 详情页（list 已够用）
- 真账号烟测 / 端到端联调（依赖后端真部署）

## Decisions

### 1. Campaign 编辑：路由跳页 vs dialog

- **选择**：编辑跳路由 `/campaigns/:id/edit`（独占整个 Main 区域，9-tab 全显示）；新建保留 dialog（仅必需字段）
- **理由**：80+ 字段塞 dialog 体验差；路由页给足空间
- **替代**：drawer 抽屉 → 仍然太挤；分页向导 → 步骤太多反复点烦

### 2. CodeMirror 6 而非 Monaco / 纯 textarea

- **选择**：CodeMirror 6 + lang-json（JsonLogic）+ lang-html + 自定义 mark decoration（Jinja2）
- **理由**：
  - Monaco ~3MB 太重
  - 纯 textarea 无语法高亮 + 无括号配对，trigger / payload 编辑频出错
  - CodeMirror 6 总 ~150KB，可接受
- **替代**：Monaco → 太重；ace-editor → 维护活跃度低

### 3. Jinja2 高亮：HTML mode + 自定义 mark

- **选择**：用 `@codemirror/lang-html`（基础 HTML 高亮）+ 自定义 ViewPlugin/decoration 标记 `{{ var }}` 与 `{% tag %}`
- **理由**：lang-jinja 第三方包维护活跃度低；HTML 是 Jinja2 模板的常见容器
- **替代**：纯 plaintext → 用户输入易错；Monaco Jinja → 太重

### 4. 角色配置嵌套子表：内嵌弹层

- **选择**：CampaignEdit 的"角色配置"tab 内嵌一张表格（kind=role/judge/polish 三类合并展示，按 kind 着色）+ "添加 / 编辑"按钮触发 `<RoleConfigDialog>` 弹层
- **理由**：role_config 行 ≤10，嵌套表格够用；prompt content 长，弹层全屏编辑体验好
- **替代**：手风琴 collapse → role 多了不直观；独立路由 `/campaigns/:id/roles` → 跳转打断流

### 5. signing_secret：仅可写不可读 + 旋转按钮

- **选择**：编辑时 input 显示 placeholder ****（实际值后端永不返回）；用户输入新值 → PATCH 时 backend 检测非空才更新；"重新生成"按钮 → POST /callback-configs/{id}/rotate-secret 让后端生成 + 一次性返回明文（前端弹窗显示一次，不存）
- **理由**：webhook-callback spec § signing_secret 加密存 DB；明文不应在前端流转
- **替代**：前端存明文 → 安全风险；用户重置时输 → UX 差

### 6. echarts manualChunks 拆分

- **选择**：vite.config.ts rollupOptions.output.manualChunks 函数：含 `node_modules/echarts` → `vendor-echarts`；含 `node_modules/element-plus` → `vendor-element-plus`；含 `node_modules/@codemirror` → `vendor-codemirror`
- **理由**：仪表板初次加载延迟最大组件就是 echarts；拆开后可被多页共享缓存
- **替代**：完全按需 import（细到组件）→ 编译时间 +50%；不拆 → DashboardView 510KB warning

### 7. Lead 分页：cursor vs offset

- **选择**：v1 用 limit/offset + el-pagination + total 计数（要求后端 /leads 返回 `{items, total}`）；如后端只返 array，前端用 limit + 判空作为"还有下一页"hint（cursor mode）
- **理由**：lead 表 ≤ 100 万行 v1 规模，offset 性能可接受
- **替代**：cursor 分页 → API 改造大；不分页 → 大数据量浏览器卡

### 8. 测试策略：unit + harness component test

- **选择**：vitest 单元测试 + @vue/test-utils 组件渲染测试；不在本 change 引 Playwright
- **理由**：
  - 单元 / 组件测试覆盖率回报高
  - e2e 需要后端真部署，本 change 纯前端
- **替代**：纯 e2e → 维护成本高；纯单元 → store / wsClient 测了，组件交互没覆盖

### 9. 不引入路由级权限粒度

- **选择**：v1 admin 一种角色，所有路由对 isAuthenticated 用户都可见
- **理由**：admin 单角色已在 impl-api / impl-web 锁定；多角色 v2 候选
- **替代**：基于 role 的菜单过滤 → v1 不需要

### 10. 字段级帮助文本：从 spec 抽取

- **选择**：每个有歧义字段的 el-form-item 用 #help slot 写一行简短说明（如"打断阈值默认 800ms — 低于此用户说话不视为打断"）；说明文本来自 isales-common Pydantic field description（如已有）或 spec 里的 § Configuration 表
- **理由**：80+ 字段不带说明用户根本不知道填什么
- **替代**：单独写帮助文档 → 用户找不到；tooltip → 鼠标 hover 体验差

## Risks / Trade-offs

| 风险 | 缓解 |
|---|---|
| Campaign 9-tab 表单 80+ 字段开发量爆炸 | 按 tab 拆 PR；每 tab ~5-12 字段，分 9 PR 顺序合入；中途产出小可独立验收 |
| CodeMirror 6 配置不熟悉 → 包装组件 bug | 先做最简单的 JSON mode（lang-json 直接用）；Jinja2 mode v1 仅基础 HTML 高亮 + 简单 decoration（不做完整 Jinja2 解析） |
| Web Audio API 8kHz PCM 浏览器兼容（Safari decodeAudioData 不识 raw PCM） | v1 直接用 AudioContext.createBuffer + buffer.getChannelData(0).set() 手动构 buffer；绕过 decodeAudioData |
| pipeline_trace 数据量大（每 turn 几 KB × N turn） | lazy load + 折叠默认收起；未来加分页或筛选（v2） |
| manualChunks 配置错可能导致循环依赖 / 加载顺序错 | vite 5 manualChunks 函数 returns string；只对 node_modules 路径分类，不拆业务代码 |
| Lead 分页 total 字段后端不支持 | 前端代码同时支持 `{items, total}` 与裸 array 两种响应；后端有 total 用之，没有就 fallback cursor |
| 测试覆盖加 25 个一次性合入 review 难 | 按测试目标对象分批：stores / utils / api / components 四组各一 PR |
| ESLint 加入后存量代码可能 lint warning | 第一次跑允许 warning + 渐进修；不强制 0 warning（后续 PR 可逐步收紧） |
| 表单字段帮助文本质量参差 | 从 spec 文档摘抄 + Pydantic field description；不强求每字段都有，重要的优先（默认值少 / 含义不显然的） |
| signing_secret rotate endpoint 后端可能未实现 | 前端先调用，404/501 时按钮提示"后端未实现"，记 follow-up；不阻塞编辑流程 |
| /calls/{id}/trace endpoint 在 impl-api 已声明但实施可能简化 | 折叠面板用 try/catch 包；endpoint 返 404 时显示"后端未提供" |

## Migration Plan

不适用——纯前端补充，不动 schema / 数据。

部署：

1. `cd isales-web && npm install`（CodeMirror 6 等新依赖）
2. `npm run typecheck && npm test && npm run build`
3. 拷 dist/ 到主机 → reload nginx

回滚：拷旧 dist/ 即可，不影响后端 / DB。

## Open Questions

- CodeMirror Jinja2 高亮做到什么程度：v1 基础 ``{{ }}`` `{% %}` mark；完整 Jinja2 grammar v2
- 9 tab 编辑表单的字段是否要全覆盖：v1 覆盖 80+ 字段中"运营常用"的（约 60 个）；冷僻字段（如 transfer_llm_prompt_version_id 关联编辑）留 v2
- KeyValueEditor（custom_data 用）是否需要类型推断：v1 仅 string 值；number/bool/object v2
- 设备列表 push vs 30s 轮询：v1 维持轮询（spec 没演进 device_status_changed event）；后端如要加 push 则在另一个 change 同步 spec + 实施
- analytics 页 7 天是否要加自定义时间范围 selector：v1 fixed 7 天；自定义 v2
- callback_log 详情页：当前列表已展示主要字段（status / retry / response_status / error_message）；详情页 v2 候选（请求体 + 响应体 + 重试历史时间轴）
- vue-router 进度条（NProgress）：v1 不做（loading skeleton 已够）；如有需求 v2
- 全局错误兜底：本 change 加 ErrorBoundary 组件 包裹 router-view，捕获组件内未处理异常 → 渲染 fallback；目前只有 axios interceptor 拦截网络错
- pinia DevTools：本 change 默认开启（vite dev mode + pinia 自动注册）；生产构建禁用
