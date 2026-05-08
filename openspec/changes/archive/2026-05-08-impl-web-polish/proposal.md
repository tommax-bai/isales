## Why

stage 7 的 impl-web 已经把 13 个路由 minimal 版本上线（4 vitest 全绿、vue-tsc 干净、build 通过、Nginx 部署配置完备），但 archive 时明确标了 32 个 follow-up 项。其中两类阻塞 v1 真上线：

1. **Campaign 9-tab 嵌套配置缺失**——当前 dialog 只能填 name/concurrency/default_replies，剩下 80+ 个 Campaign 字段（角色 / 裁判 / 润色 / 沉默 / 打断保护 / 转人工 / 收尾 / 时间窗口 / 重试 / 勿打 / 回调）一个都没在前端。运营要跑真 campaign 必须直连 DB 改字段，违反 v1 完成标准 #4。
2. **回调编辑器缺失**——CallbackConfigList 只能浏览，不能新建 / 编辑 trigger（JsonLogic）+ payload_template（Jinja2）。运营要配 webhook 回调必须直接 SQL insert，同样违反完成标准。

剩下的 follow-up（音色试听 / Lead 编辑 dialog / pipeline_trace 折叠 / echarts manualChunks / 测试覆盖增强 / 404 / loading skeleton 等）属于体验提升，本 change 一并收掉。

## What Changes

- **Campaign 9-tab 嵌套配置编辑（最大块）**
  - `views/Campaigns/CampaignEdit.vue`：路由 `/campaigns/:id/edit`（替换当前 dialog）；el-tabs 9 个页签：基础 / 角色配置 / 沉默激活 / 打断保护 / 转人工 / 收尾 / 时间窗口 / 重试跟进 / 勿打 / 回调
  - 每个 tab 对应 `CampaignEditTabXxx.vue` 子组件，按 isales-common Campaign 字段分组渲染表单（共 80+ 字段）
  - 角色配置 tab：嵌套 `<RoleConfigTable>`（kind=role/judge/polish 三类各自子表）+ `<RoleConfigDialog>` 弹层编辑（model / temperature / top_p / current_prompt_version_id 关联的 prompt content）
  - 垫词 tab：嵌套 `<FillerSetTable>` + `<FillerSetDialog>` + `<FillerPhraseSubTable>`
  - 回调 tab：嵌套 `<CallbackConfigSubTable>`（链到独立的 callback-configs 页编辑细节）
  - 时间窗口 + 节假日 tab：嵌套 `<TimeWindowEditor>` + `<HolidayPicker>`（直接调用 /holidays endpoint）
  - 列表页 CampaignList 的"编辑"按钮改成跳路由（保留 dialog 兼容仅用于新建）
  - 字段级帮助文本（el-form-item 的 #help slot）覆盖每个有歧义的字段
  - 提交：单次 PATCH /campaigns/{id}（后端已支持嵌套）；422 错误展开成字段级 form errors

- **CodeMirror 6 JsonLogic / Jinja2 编辑器**
  - 新依赖：`@codemirror/state` / `@codemirror/view` / `@codemirror/lang-json` / `@codemirror/commands`
  - `components/Common/CodeEditor.vue`：薄 v-model 包装，props `mode: 'json' | 'jinja2'`、`height` 默认 200px、`placeholder`
  - Jinja2 模式：用 `@codemirror/lang-html` + 自定义 ``{{ }}`` `{% %}` 高亮标记；不引 lang-jinja 第三方包（重）
  - `views/Callbacks/CallbackConfigEdit.vue`：取代 placeholder，包含 trigger（JsonLogic 编辑）+ payload_template（Jinja2 编辑）+ url / method / signing_secret（密文掩码 + 重新生成）/ retry_policy / timeout
  - 本地校验：trigger JSON.parse 通过即标 valid；JsonLogic eval 留 follow-up（v1 仅做语法校验，依赖后端 dry-run）
  - 后端 dry-run：POST /callback-configs/validate 验 trigger（占位 ctx）+ render payload_template；前端展示渲染结果
  - signing_secret：编辑时显示掩码 ****（API 应返回掩码，前端不存原值）；按"重新生成"按钮 → POST /callback-configs/{id}/rotate-secret

- **Lead 单条编辑 dialog**
  - `components/Lead/LeadEditDialog.vue`：phone / name / source / status select + custom_data 用 `<KeyValueEditor>` 组件（动态行 add/remove）
  - LeadList 表格新增"编辑"按钮触发 dialog
  - 状态枚举与 retry-followup spec 对齐

- **音色试听（Web Audio API）**
  - `components/VoiceModel/VoicePreview.vue`：input 文本 + 试听按钮 → fetch /voice-models/{id}/preview ArrayBuffer → AudioContext.decodeAudioData → AudioBufferSourceNode 播放
  - 8kHz mono 16-bit LE PCM 直接从 raw bytes 构造 AudioBuffer（不走 decodeAudioData，因为 PCM raw 不是封装格式）
  - VoiceModelList 表格"试听"按钮触发

- **pipeline_trace 折叠面板（CallDetail）**
  - `components/Calls/PipelineTracePanel.vue`：el-collapse 按 turn_id 折叠；展开时 lazy GET /calls/{id}/trace（PR #8 已经规划但 deferred）
  - 每个 turn 展示 user_input + role_candidates 表格（候选 / parsed json / 解析失败 marker / token / 时延）+ judge_results 矩阵（候选 × 裁判 通过/否决）+ polish_input/output + final_selected_candidate_index
  - JSON 字段用 `<pre>` 折行显示

- **echarts manualChunks 优化**
  - `vite.config.ts` rollupOptions.output.manualChunks：把 echarts 拆出独立 chunk，DashboardView chunk 从 510KB → < 200KB
  - 也拆 element-plus 自己一个 chunk

- **404 + 空状态 + loading skeleton**
  - `views/NotFoundView.vue`：404 illustration + 返回首页按钮（取代当前 PlaceholderView 兼任 404）
  - 列表组件统一 loading skeleton（el-skeleton）
  - 数据为空时统一 empty-state（el-empty + 行动按钮）

- **eslint + Prettier 配置 + GitHub Actions CI**
  - `.eslintrc.cjs`（@vue/eslint-config-typescript 推荐）+ `.prettierrc`
  - `.github/workflows/ci.yml`：npm install + lint + typecheck + test + build

- **vitest 单元覆盖增强**
  - 目标：覆盖 stores（auth / campaigns / leads / monitoring）+ utils/wsClient 重连逻辑 + api/client 401 拦截器 + TranscriptTimeline icon 映射
  - 大约 ~25 个新测试

- **Lead 列表分页**
  - 当前 LeadList 是 limit=50 + offset=0 一次性加载；本 change 加 el-pagination + total 计数
  - 配套：API 端 /leads 应返回 `{items, total}`；如未支持，前端用 next/prev cursor

- **设备状态 push（可选）**
  - 如果 isales-api 演进出 `/ws/devices` endpoint，前端切到 push；本 change **不** 引入新事件类型，仅做"已存在 endpoint 时的客户端"
  - 当前 30s 轮询保留作 fallback

## Capabilities

### New Capabilities

无。

### Modified Capabilities

无 spec delta — 本 change 全部在已有 capability（service-communication / data-model / 各业务 spec）的 UI 层填充实施细节，不修改 requirement。

## Impact

- **isales-web 仓库改动**：新增 ~30 个 .vue 组件 + ~10 个测试；vite.config.ts 改 manualChunks；package.json 加 CodeMirror 6 + ESLint 依赖；deploy/ 不动
- **后端依赖**：
  - 必需：isales-api 已有的 PATCH /campaigns/{id} 嵌套 + POST /callback-configs/validate dry-run + GET /calls/{id}/trace 端点都已存在（impl-api 阶段 2B 归档）
  - 可选：POST /callback-configs/{id}/rotate-secret（如未存在，本 change 加 placeholder + 后端 follow-up）
  - 可选：/leads 返回 total（如未支持，前端用 cursor 分页）
- **可独立实施**：纯前端，不阻塞任何后端工作；deferred 项分批合入更稳；可与 stage 6（hardware）并行
- **不影响**：所有 Python 服务零改动
- **新依赖**：@codemirror/state / view / lang-json / commands；@vue/eslint-config-typescript（已声明但未配置）；prettier
- **超出本 change 范围**：
  - Playwright e2e（v2）
  - 移动端响应式（v2）
  - i18n（v2）
  - 多租户（v2）
  - 暗色模式（v2）
  - 接通率多维筛选 + 时间范围选择器（v2 — analytics 页保持 7 天 fixed）
  - prompt_version 历史 diff UI（v2）
  - JsonLogic 客户端 eval（v2 — 当前依赖后端 dry-run）
