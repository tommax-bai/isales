## 1. 状态合并（CampaignDetail form → CampaignBase）

- [ ] 1.1 `CampaignDetail.vue`：把 `form` 从 8 字段子集扩成 `reactive<CampaignBase>`（`{ ...CAMPAIGN_DEFAULTS }` 初始化）；`onRefresh` 改 `Object.assign(form, detail)` 全量加载；核对 CampaignBase 全字段覆盖（routing_rules/tools/silence_*/interruption_*/transfer_*/wrap_up_*/retry_*/do_not_call_* 等）
- [ ] 1.2 新增只读 `roleConfigs` ref，`onRefresh` 时 `detail.role_configs` 灌入（仅供 Routing/Tools 小节取 referee label，不参与保存）
- [ ] 1.3 现有 basic/时段/3 PromptTier 卡/FillerEditor 小节保持不变（不回归）

## 2. 保存合并

- [ ] 2.1 合并 `CampaignEdit.buildPayload`（greeting 归一为 null、omit callback_configs；**不含 role_configs/filler_sets**——自存）进 `CampaignDetail.onSave`
- [ ] 2.2 合并 `applyFieldErrors` + `fieldErrors` reactive（422 标红）；保存失败/校验 banner
- [ ] 2.3 保存条文案改为说明两类保存：「基本信息 / 路由 / 工具 / 沉默 / 转人工 / 收尾 / 调度 等改动需保存；AI 角色与垫词各自即时保存」

## 3. 新增 9 个 form-driven 小节（逐个加 + build + 手测保存）

- [ ] 3.1 多流路由 `RoutingRulesTab`（v-model form，:role-configs=roleConfigs）
- [ ] 3.2 工具触发 `ToolsTab`（v-model form，:role-configs=roleConfigs）
- [ ] 3.3 沉默激活 `SilenceTab`（v-model form，:field-errors=fieldErrors）
- [ ] 3.4 打断保护 `InterruptionTab`（v-model form，:field-errors）
- [ ] 3.5 转人工 `TransferTab`（v-model form，:field-errors）
- [ ] 3.6 收尾 `WrapUpTab`（v-model form，:field-errors）
- [ ] 3.7 重试·跟进 `RetryFollowUpTab`（v-model form，:field-errors）
- [ ] 3.8 勿打 `DoNotCallTab`（v-model form）
- [ ] 3.9 回调 `CallbacksTab`（:model-value=callbackConfigs，:campaign-id；保持只读跳转编辑页）
- [ ] 3.10 小节统一视觉（card + 标题），顺序按 design D1；**不**引入 BasicTab/TimeWindowTab/RoleConfigTab/FillerTab（避免双份编辑）

## 4. 删除独立高级编辑器

- [ ] 4.1 删 `CampaignDetail` 的「高级配置」按钮（模板）+ `goAdvanced()`
- [ ] 4.2 删 `router/index.ts` 的 `operations-campaign-edit` 路由 + `CampaignEdit` import + D6 注释
- [ ] 4.3 删 `views/Campaigns/CampaignEdit.vue` 整文件
- [ ] 4.4 grep 确认无残留 inbound ref（operations-campaign-edit / CampaignEdit import）

## 5. 清过期文案

- [ ] 5.1 `CampaignDetail` 注释「4-tier/三层」→ 双 LLM 门控（主对话/决策/抽取）
- [ ] 5.2 `CampaignDetail` 注释「原运营区」→ 删/简化（goMonitor 注释）
- [ ] 5.3 `components/Campaign/RoleConfigDialog.vue` placeholder「main_judge」→「main_referee」
- [ ] 5.4 `tests/campaignEdit.test.ts`「main_judge」fixture → 随 CampaignEdit 删除迁移（见 §6）
- [ ] 5.5 （DEFER 记录）`PromptTierEditor` 组件名 + `PromptTierProviderId` 类型改名——本次不做，注明内部命名 churn

## 6. 测试

- [ ] 6.1 删 `tests/campaignEdit.test.ts`（CampaignEdit 已删）
- [ ] 6.2 新增/扩 `tests/campaignDetail.test.ts`：onSave buildPayload 含全字段、omit callback_configs、greeting 归一；9 个小节渲染；roleConfigs 传递
- [ ] 6.3 全套 vitest + vue-tsc + lint 全绿

## 7. 部署与收尾

- [ ] 7.1 `npm run build`（vue-tsc + vite）→ `rsync -az --delete dist/` → ECS `/var/www/isales-web/` → `nginx -t` + reload；smoke `index 200`
- [ ] 7.2 备份旧 dist（`/opt/isales/backups/scene-onepage-<ts>/`）；回滚=rsync 回旧 + reload
- [ ] 7.3 更新 `deploy/cloud/STATE.md`（web 场景单页 + 删高级编辑器 + 文案清理）
- [ ] 7.4 手测：进度/启停/监控不回归；基本信息+TTS 试听；9 小节编辑+统一保存；422 标红；AI 角色/垫词即时存
- [ ] 7.5 `openspec validate web-admin-scene-single-page-config --strict` 通过；tasks 回写 commit/PR
- [ ] 7.6 archive 顺序与 `web-admin-one-role-ia-consolidation` 协调（建议其先 archive）
