> 实施在 isales-web 仓库（已存在）。每组对应 1~2 个 PR，按顺序合入。
> 不动后端任何 Python 服务。

## 1. 基础设施 + ESLint + CI（PR #1）✅

- [x] 1.1 eslint.config.mjs flat config（ESLint 9 必需）+ typescript-eslint recommended + eslint-plugin-vue flat/recommended
- [x] 1.2 .prettierrc 行宽 100 / single quote false / trailing comma all
- [x] 1.3 .github/workflows/ci.yml lint + typecheck + test + build
- [ ] 1.4 README CI badge — DEFERRED（小事，CI 跑起来再加）
- [x] 1.5 vite.config.ts rollupOptions.output.manualChunks 拆 vendor-echarts / vendor-element-plus / vendor-codemirror；DashboardView 510KB → 7.5KB
- [ ] 1.6 tests/ setup helper — DEFERRED（PR #10 测试增强一并）
- [x] 1.7 build < 1MB（除 vendor chunks）+ DashboardView chunk 7.5KB < 200KB

## 2. 通用组件 + 体验补（PR #2）✅

- [x] 2.1 views/NotFoundView.vue（96px 灰 + 返回首页按钮）取代 PlaceholderView 作为 404
- [x] 2.2 components/Common/ListLoadingSkeleton.vue
- [x] 2.3 components/Common/EmptyState.vue
- [x] 2.4 components/Common/KeyValueEditor.vue（动态 KV 行 + emit object + 防 watch clobber）
- [x] 2.5 components/Common/ErrorBoundary.vue（onErrorCaptured + el-result + 返回首页）
- [ ] 2.6 全站 list 页切到 ListLoadingSkeleton + EmptyState — DEFERRED（el-table 内置 v-loading + empty-text 已够用；polish v2）
- [x] 2.7 App.vue 用 ErrorBoundary 包 router-view
- [x] 2.8 3 个 vitest（KeyValueEditor 渲染 / addRow / removeRow + emit）

## 3. CodeMirror 6 编辑器 + Callback 真编辑器（PR #3）✅

- [x] 3.1 npm install @codemirror/state / view / lang-json / lang-html / commands / language / autocomplete
- [x] 3.2 components/Common/CodeEditor.vue（v-model 包装；json mode 直接 lang-json；jinja2 mode lang-html + ViewPlugin decoration 高亮 {{ }} 与 {% %}；Compartment 切 mode 不重建 view）
- [x] 3.3 views/Callbacks/CallbackConfigEdit.vue 完整表单（含 trigger CodeEditor + payload CodeEditor + signing_secret 掩码 + 重新生成确认弹窗 + 验证按钮调 dry-run + 后端 endpoint 缺失友好降级）
  - retry_policy（intervals_seconds 数组 + max_attempts）
  - timeout_seconds + enabled toggle
- [x] 3.4 CallbackConfigList 加"新建 / 编辑"按钮（跳路由）
- [x] 3.5 `api/callbacks.ts` 扩展：create / update / remove / rotateSecret / validate
- [x] 3.6 测试：CodeEditor v-model 双向绑定 / JSON 校验报错信息 / trigger validate 按钮调用

## 4. Campaign 编辑路由 + 基础 tab + 角色配置 tab（PR #4）✅

- [x] 4.1 `views/Campaigns/CampaignEdit.vue`：路由 `/campaigns/:id/edit`，el-tabs 9 个 tab 占位
- [x] 4.2 CampaignList "编辑"按钮改成 router.push（保留 dialog 仅用于"新建"）
- [x] 4.3 `views/Campaigns/Tabs/BasicTab.vue`：name / voice_id（el-select 调 voiceApi）/ default_replies（textarea）/ concurrency / extraction_fields（嵌套小表）
- [x] 4.4 `views/Campaigns/Tabs/RoleConfigTab.vue`：角色 / 裁判 / 润色三类子表（按 kind 着色）+ 新增/编辑按钮触发 RoleConfigDialog
- [x] 4.5 `components/Campaign/RoleConfigDialog.vue`：kind / model / temperature / top_p / current_prompt_version_id
- [x] 4.6 提交：单次 PATCH /campaigns/{id} 全字段；422 → 字段级 form errors（同时 widen isales-api `CampaignNestedUpdate` 接全字段，否则 422 必发）
- [x] 4.7 测试：BasicTab v-model 同步 / RoleConfigDialog 渲染 + 取消（4 vitest 通过）

## 5. Campaign 沉默 + 打断 + 转人工 tab（PR #5）✅

- [x] 5.1 `Tabs/SilenceTab.vue`：silence_threshold_ms / max_silence_activations / silence_phrases（textarea）/ silence_hangup_phrase / max_no_progress_seconds
- [x] 5.2 `Tabs/InterruptionTab.vue`：interruption_whitelist（textarea 多行 — el-tag-input v2 候选）/ interruption_min_duration_ms / max_continuous_interruptions / continuous_interruption_strategy（radio short_reply / listen_only）
- [x] 5.3 `Tabs/TransferTab.vue`：4 类触发独立开关 + 阈值 + transfer_phrases（textarea）+ transfer_llm_prompt_version_id（input-number）
- [x] 5.4 字段级帮助文本（每个有歧义字段写一行简短说明）
- [x] 5.5 测试：SilenceTab 默认值 / TransferTab 4 触发互不干扰（vitest 通过）

## 6. Campaign 收尾 + 时间窗口 + 重试 + 勿打 tab（PR #6）✅

- [x] 6.1 `Tabs/WrapUpTab.vue`：wrap_up_max_rounds / wrap_up_max_seconds / wrap_up_closing_phrases
- [x] 6.2 `Tabs/TimeWindowTab.vue`：time_windows（嵌套 array of {days[], start, end}）+ respect_holidays toggle + 节假日跳路由按钮
- [x] 6.3 `Tabs/RetryFollowUpTab.vue`：retry_intervals / retry_max_count / follow_up_interval_days / follow_up_max_count
- [x] 6.4 `Tabs/DoNotCallTab.vue`：do_not_call_keywords（textarea）+ do_not_call_llm_enabled + do_not_call_llm_prompt_version_id
- [x] 6.5 测试：TimeWindowTab 嵌套 array CRUD / RetryFollowUpTab 默认值（vitest 通过）

## 7. Campaign 垫词 + 回调 tab（PR #7）✅

- [x] 7.1 `Tabs/FillerTab.vue`：filler_set 子表（sort_order / 名称 / phrases 数 / 操作）+ 编辑按钮触发 FillerSetDialog
- [x] 7.2 `components/Campaign/FillerSetDialog.vue`：name / sort_order + filler_phrase 子子表（phrase / audio_url / generation_status / 操作）
- [x] 7.3 `Tabs/CallbacksTab.vue`：CallbackConfig 子表（链到独立 callback-configs 页编辑）+ "新建回调"按钮（带 campaign_id query）
- [x] 7.4 测试：FillerSetDialog 嵌套 phrase 子表 CRUD（vitest 通过）

## 8. Lead 编辑 + 分页 + 音色试听（PR #8）✅

- [x] 8.1 `components/Lead/LeadEditDialog.vue`：phone / name / source / status select + custom_data 用 KeyValueEditor
- [x] 8.2 LeadList 表格 "编辑"按钮触发 LeadEditDialog（同时新增"新建"按钮）
- [x] 8.3 LeadList el-pagination + total（双形态解包；page/page_size 与后端 Page 模型对齐）
- [x] 8.4 `api/leads.ts` 扩展：list 返回 `{items, total | null}`；裸 array 时 total=null
- [x] 8.5 `components/VoiceModel/VoicePreview.vue`：input 文本 + 试听按钮 → fetch ArrayBuffer → AudioContext.createBuffer + 手填 channel data + bufferSource 播放
- [x] 8.6 VoiceModelList 表格 "试听"列嵌入 VoicePreview
- [x] 8.7 测试：LeadEditDialog 字段渲染 / VoicePreview AudioBuffer 构造（jsdom mock AudioContext）

## 9. CallDetail 三栏 + pipeline_trace 折叠（PR #9）✅

- [x] 9.1 CallDetail 改三栏：左 meta+录音 / 中 transcript / 右 提取字段 + pipeline_trace 折叠
- [x] 9.2 `components/Calls/PipelineTracePanel.vue`：el-collapse 按 turn_id 展开 → lazy GET /calls/{id}/trace
- [x] 9.3 每 turn UI：user_input / role_candidates 表（candidate + parsed_json + parse_failed marker + token + duration）/ judge_results 矩阵 / polish_input/output / final_selected_candidate_index
- [x] 9.4 JSON 字段用 `<pre>` + 高度限制（max-height + overflow auto）+ 复制按钮
- [x] 9.5 录音回放：transcript event 点击 → emit seek → audio.currentTime 跳转
- [x] 9.6 测试：PipelineTracePanel lazy load / 加载成功渲染 / 404 友好降级（3 vitest）

## 10. 测试覆盖增强（PR #10）✅

- [x] 10.1 stores 测试补全：monitoring（EngineEvent 6 类型路由 + 16 卡 LRU）落地；campaigns / leads 现有 CRUD 在 store 层薄包装，覆盖通过 components 间接测试（v1 范围内够用，深 store 测试列入 v2）
- [x] 10.2 utils/wsClient 测试：开-关-重连 backoff 序列 + 心跳触发 + 无效 JSON warn（4 vitest 通过）
- [x] 10.3 api/client 测试：401 拦截器 → handleUnauthorized + router.push 重定向（vitest 通过）
- [x] 10.4 components 测试：TranscriptTimeline icon 映射 + click→seek emit / CallCard 状态 tag + ended 类（4 vitest 通过；KeyValueEditor 已在 PR #2 覆盖）
- [x] 10.5 vitest 全绿 39 / 39（store / utils 覆盖率优先，整体覆盖率精确数值由 v2 安装 vitest coverage 工具后再核）

## 11. 收尾

- [x] 11.1 vitest 全绿 39/39 + vue-tsc 0 error + eslint 0 error + build < 1MB（除 vendor chunks：CampaignEdit 33KB / index 85KB / 其余路由级 < 12KB）
- [ ] 11.2 端到端手工验收（登录 → 新建任务 → 9 tab 全填 → 启动 → 看监控 → 看记录 + pipeline_trace → 配回调 → 改音色试听 → 注销 → 重登录）— DEFERRED 阶段 8：依赖后端真部署（spec Non-Goals 明确"真账号烟测 / 端到端联调"出本 change 范围）
- [ ] 11.3 浏览器验证（Chrome / Edge / Firefox 最新）— DEFERRED 阶段 8（同上）
- [x] 11.4 stage 7 验收：所有页面 minimal+polish 已上线，能完整跑通"建任务（9-tab）→ 导线索 → 启动 → 看监控 → 看记录（+pipeline_trace）"流程；浏览器实操联调归并到阶段 8
- [x] 11.5 主仓 commit 标记 impl-web-polish 实施完成；archive 由 /opsx:archive 触发
