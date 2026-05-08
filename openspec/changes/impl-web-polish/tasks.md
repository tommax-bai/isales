> 实施在 isales-web 仓库（已存在）。每组对应 1~2 个 PR，按顺序合入。
> 不动后端任何 Python 服务。

## 1. 基础设施 + ESLint + CI（PR #1）

- [ ] 1.1 `.eslintrc.cjs`（@vue/eslint-config-typescript 推荐 + import 排序）
- [ ] 1.2 `.prettierrc`（行宽 100 / single quote / trailing comma all）
- [ ] 1.3 `.github/workflows/ci.yml`：npm install + lint + typecheck + test + build
- [ ] 1.4 README CI badge + 部署章节微调
- [ ] 1.5 `vite.config.ts` rollupOptions.output.manualChunks：vendor-echarts / vendor-element-plus / vendor-codemirror（解决 DashboardView 510KB warning）
- [ ] 1.6 `tests/` 目录加 setup helper（Pinia testing instance / mock router / 公共 fixtures）
- [ ] 1.7 测试：build 后 dist/ 总大小 < 1MB；DashboardView chunk < 200KB

## 2. 通用组件 + 体验补（PR #2）

- [ ] 2.1 `views/NotFoundView.vue`：404 illustration + 返回首页（取代 PlaceholderView 兼任 404）
- [ ] 2.2 `components/Common/ListLoadingSkeleton.vue`：列表 loading 通用骨架
- [ ] 2.3 `components/Common/EmptyState.vue`：空状态 + 行动按钮 slot
- [ ] 2.4 `components/Common/KeyValueEditor.vue`：动态 key-value 行（add / remove / 表单校验）
- [ ] 2.5 `components/Common/ErrorBoundary.vue`：组件未捕获异常兜底渲染
- [ ] 2.6 全局应用：所有 list 页（13 个）切到 ListLoadingSkeleton + EmptyState
- [ ] 2.7 main.ts 用 ErrorBoundary 包 router-view
- [ ] 2.8 测试：KeyValueEditor add/remove / EmptyState slot

## 3. CodeMirror 6 编辑器 + Callback 真编辑器（PR #3）

- [ ] 3.1 npm install @codemirror/state @codemirror/view @codemirror/lang-json @codemirror/commands @codemirror/language @codemirror/autocomplete
- [ ] 3.2 `components/Common/CodeEditor.vue`：薄 v-model 包装，props mode=json|jinja2、height、placeholder
  - JSON 模式：`@codemirror/lang-json` 直接用 + 括号配对 + 行号
  - Jinja2 模式：`@codemirror/lang-html` 基础 + ViewPlugin decoration 高亮 ``{{ }}`` `{% %}`
- [ ] 3.3 `views/Callbacks/CallbackConfigEdit.vue`：路由 `/callback-configs/:id/edit` + `/callback-configs/new`
  - 名称 / URL / method（select GET/POST/PATCH）
  - trigger（CodeEditor json，本地 JSON.parse 校验 + "测试 trigger" 按钮调 POST /callback-configs/validate）
  - payload_template（CodeEditor jinja2 + "测试渲染" 按钮）
  - signing_secret 掩码 input + "重新生成" 按钮（POST /callback-configs/{id}/rotate-secret，404 时提示后端未实现）
  - retry_policy（intervals_seconds 数组 + max_attempts）
  - timeout_seconds + enabled toggle
- [ ] 3.4 CallbackConfigList 加"新建 / 编辑"按钮（跳路由）
- [ ] 3.5 `api/callbacks.ts` 扩展：create / update / remove / rotateSecret / validate
- [ ] 3.6 测试：CodeEditor v-model 双向绑定 / JSON 校验报错信息 / trigger validate 按钮调用

## 4. Campaign 编辑路由 + 基础 tab + 角色配置 tab（PR #4）

- [ ] 4.1 `views/Campaigns/CampaignEdit.vue`：路由 `/campaigns/:id/edit`，el-tabs 9 个 tab 占位
- [ ] 4.2 CampaignList "编辑"按钮改成 router.push（保留 dialog 仅用于"新建"）
- [ ] 4.3 `views/Campaigns/Tabs/BasicTab.vue`：name / voice_id（el-select 调 voiceApi）/ default_replies（textarea）/ concurrency / extraction_fields（KeyValueEditor）
- [ ] 4.4 `views/Campaigns/Tabs/RoleConfigTab.vue`：角色 / 裁判 / 润色三类子表（按 kind 着色）+ 新增/编辑按钮触发 RoleConfigDialog
- [ ] 4.5 `components/Campaign/RoleConfigDialog.vue`：kind / model（select doubao-pro/lite/gpt-4o-mini/gpt-4o）/ temperature / top_p / current prompt（CodeEditor json placeholder, 实际是 plaintext）
- [ ] 4.6 提交：单次 PATCH /campaigns/{id} 全字段；422 → 字段级 form errors
- [ ] 4.7 测试：CampaignEdit 路由跳转 / BasicTab v-model 同步 / RoleConfigDialog 校验

## 5. Campaign 沉默 + 打断 + 转人工 tab（PR #5）

- [ ] 5.1 `Tabs/SilenceTab.vue`：silence_threshold_ms / max_silence_activations / silence_phrases（textarea 多行）/ silence_hangup_phrase / max_no_progress_seconds
- [ ] 5.2 `Tabs/InterruptionTab.vue`：interruption_whitelist（标签输入 el-tag-input）/ interruption_min_duration_ms / max_continuous_interruptions / continuous_interruption_strategy（radio short_reply / listen_only）
- [ ] 5.3 `Tabs/TransferTab.vue`：4 类触发独立开关 + 阈值 + transfer_phrases（textarea）+ transfer_llm_prompt_version_id（select）
- [ ] 5.4 字段级帮助文本（spec § Configuration 表抽取）
- [ ] 5.5 测试：SilenceTab 默认值 / TransferTab 4 触发互不干扰

## 6. Campaign 收尾 + 时间窗口 + 重试 + 勿打 tab（PR #6）

- [ ] 6.1 `Tabs/WrapUpTab.vue`：wrap_up_max_rounds / wrap_up_max_seconds / wrap_up_closing_phrases
- [ ] 6.2 `Tabs/TimeWindowTab.vue`：time_windows（嵌套 array of {weekday, start, end}）+ respect_holidays toggle + 节假日跳路由按钮
- [ ] 6.3 `Tabs/RetryFollowUpTab.vue`：retry_intervals / retry_max_count / follow_up_interval_days / follow_up_max_count
- [ ] 6.4 `Tabs/DoNotCallTab.vue`：do_not_call_keywords（标签输入）+ do_not_call_llm_enabled + do_not_call_llm_prompt_version_id
- [ ] 6.5 测试：TimeWindowTab 嵌套 array CRUD / RetryFollowUpTab 默认值

## 7. Campaign 垫词 + 回调 tab（PR #7）

- [ ] 7.1 `Tabs/FillerTab.vue`：filler_set 子表（sort_order / 名称 / phrases 数 / 操作）+ 编辑按钮触发 FillerSetDialog
- [ ] 7.2 `components/Campaign/FillerSetDialog.vue`：name / sort_order + filler_phrase 子子表（phrase / audio_url / generation_status / 操作）
- [ ] 7.3 `Tabs/CallbacksTab.vue`：CallbackConfig 子表（关联到独立 callback-configs 页详细编辑）+ 跳"新建回调"按钮（带 campaign_id query）
- [ ] 7.4 测试：FillerSetDialog 嵌套 phrase 子表 CRUD

## 8. Lead 编辑 + 分页 + 音色试听（PR #8）

- [ ] 8.1 `components/Lead/LeadEditDialog.vue`：phone / name / source / status select + custom_data 用 KeyValueEditor
- [ ] 8.2 LeadList 表格 "编辑"按钮触发 LeadEditDialog
- [ ] 8.3 LeadList el-pagination + total（API 端 /leads 返回 `{items, total}`；如裸 array 走 cursor mode）
- [ ] 8.4 `api/leads.ts` 扩展：list 返回类型支持两种形态；前端解包统一为 `{items, total?}`
- [ ] 8.5 `components/VoiceModel/VoicePreview.vue`：input 文本 + 试听按钮 → fetch /voice-models/{id}/preview ArrayBuffer → AudioContext.createBuffer + buffer.copyToChannel + AudioBufferSourceNode 播放
- [ ] 8.6 VoiceModelList 表格 "试听"列嵌入 VoicePreview
- [ ] 8.7 测试：LeadEditDialog 字段双向 / VoicePreview AudioBuffer 构造（jsdom mock AudioContext）

## 9. CallDetail 三栏 + pipeline_trace 折叠（PR #9）

- [ ] 9.1 CallDetail 改三栏：左 lead+meta / 中 transcript / 右 提取字段 + pipeline_trace 折叠
- [ ] 9.2 `components/Calls/PipelineTracePanel.vue`：el-collapse 按 turn_id 展开 → lazy GET /calls/{id}/trace 返回 pipeline_trace[]
- [ ] 9.3 每 turn UI：user_input / role_candidates 表（候选 + parsed_json + parse_failed marker + token + duration）/ judge_results 矩阵 / polish_input/output / final_selected_candidate_index
- [ ] 9.4 JSON 字段用 `<pre>` + 高度限制 + 复制按钮
- [ ] 9.5 录音回放：根据 transcript event ts 跳转 audio.currentTime（点击 transcript event 触发）
- [ ] 9.6 测试：PipelineTracePanel lazy load / 折叠状态保持

## 10. 测试覆盖增强（PR #10）

- [ ] 10.1 stores 测试补全：campaigns（CRUD action 全路径）/ leads（fetchAll / 过滤）/ monitoring（EngineEvent 6 类型路由 + 16 卡 LRU）
- [ ] 10.2 utils/wsClient 测试：开-关-重连 backoff 序列 + 心跳触发 + 未知 type warn
- [ ] 10.3 api/client 测试：401 拦截器 → handleUnauthorized + router.push 行为
- [ ] 10.4 components 测试：TranscriptTimeline icon 映射 / CallCard 状态 tag / KeyValueEditor 增删
- [ ] 10.5 vitest 覆盖率 ≥ 70%（store / utils 覆盖率优先；views ≥ 30% 即可）

## 11. 收尾

- [ ] 11.1 vitest 全绿 + vue-tsc 0 error + eslint 0 error（warning 允许）+ build < 1MB
- [ ] 11.2 端到端手工验收：登录 → 新建任务 → 9 tab 全填 → 启动 → 看监控 → 看记录 + pipeline_trace → 配回调 → 改音色试听 → 注销 → 重登录
- [ ] 11.3 浏览器验证：Chrome / Edge 最新；Firefox 最新（v1 不验证 Safari）
- [ ] 11.4 IMPLEMENTATION_PLAN 阶段 7 验收清单全部勾选（v1 完成标准 #4 真达成）
- [ ] 11.5 主仓 commit 标记 impl-web-polish 实施完成；archive 由 /opsx:archive 触发
