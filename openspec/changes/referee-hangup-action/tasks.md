## 1. isales-common — 数据契约（先行，下游依赖）

- [ ] 1.1 `enums.py`：`HangupCause` 新增 `REFEREE_HANGUP = "referee_hangup"`（应用层段，紧邻 `manual_hangup`）
- [ ] 1.2 `schemas/jsonb/routing_rule.py`：新增 `HangupAction{type: Literal["hangup"], closing_phrase: str | None = Field(default=None, max_length=512)}`
- [ ] 1.3 `routing_rule.py`：把 `RoutingAction` union 扩为 `TransitionAction | RestructureAction | HangupAction`（保持按 `type` 的 discriminated union）
- [ ] 1.4 `schemas/pipeline.py` / 相关 PipelineConfig：确认 routing_rules 类型引用自动覆盖 HangupAction（无需额外字段）
- [ ] 1.5 `tests/test_routing_rule.py`：补 HangupAction 用例——话术可选、>512 拒绝、hangup MUST NOT 带 to/goal_type/source、union round-trip
- [ ] 1.6 bump 版本 `0.7.x → 0.8.0`，更新 CHANGELOG/pyproject
- [ ] 1.7 确认无需 alembic（routing_rules 为 JSONB；hangup_cause 为 String 列，无 PG enum DDL）

## 2. isales-engine — decider + run_loop + 挂断执行

- [ ] 2.1 pin `isales-common>=0.8,<0.9`
- [ ] 2.2 `pipeline/decider.py`：命中 `action.type=="hangup"` → 返回新 `DeciderAction(kind="hangup", closing_phrase=...)`；扩 DeciderAction 类型
- [ ] 2.3 `run_loop.py`：处理 hangup DeciderAction——`closing_phrase` 非空时经既有定值 TTS 播放单句（不 spawn referee、不进 WRAPPING_UP）→ `transition_to(END, reason="referee_hangup")`；为空时立即 END
- [ ] 2.4 `run_loop.py`：话术播放期间检测会话已 END / RTC 断 → 跳过剩余话术直接 finalize（复用 SPEAKING 期 user_hangup 处理）
- [ ] 2.5 `call_lifecycle.py`：`_resolve_hangup_cause` 识别 `referee_hangup`；落 `call_record.hangup_cause`
- [ ] 2.6 未知 action.type 容错：旧/未知 type fail-open 当 continue（保证回滚期 engine 不 crash，见 design 回滚节）
- [ ] 2.7 pipeline_trace：hangup 轮经既有 `matched_rule` 记录命中规则（无新列）
- [ ] 2.8 engine 单测：decider 命中 hangup→DeciderAction；run_loop 配话术/空话术两路径→END+cause；对端先挂跳过话术

## 3. isales-api — 校验

- [ ] 3.1 pin `isales-common>=0.8,<0.9`
- [ ] 3.2 确认 `routing_validation.py` / RoutingRulesReplace 对 hangup action 形状校验（主要由 common schema 管；closing_phrase 长度）
- [ ] 3.3 `tests/test_multi_referee_routing.py`：补 hangup 规则的 PUT/GET round-trip + 非法形状 422 用例

## 4. isales-web — 动作编辑器加「挂断」+ 修 goal_type bug

- [ ] 4.1 `types/campaign.ts`：新增 `HangupAction` 类型，扩 `RoutingAction` union；action 默认值表加 hangup 形状
- [ ] 4.2 `RoutingRulesTab.vue`：action 类型选择器加第三项「挂断」；`onActionTypeChange` 切到 hangup 时重置为 `{type:"hangup", closing_phrase:null}`
- [ ] 4.3 `RoutingRulesTab.vue`：hangup 类型仅渲染「挂断前话术」可选输入（留空=立即挂），并显示「挂断 vs 客户拒绝」区别提示
- [ ] 4.4 `RoutingRulesTab.vue`：修 bug——transition 目标从 `goal_achieved` 切到其它时清空 `goal_type`（新增 `onTargetChange`，`defineExpose` 暴露以便测试）
- [ ] 4.5 `tests/routingRulesTab.test.ts`：补用例——加 hangup 规则、type 切换重置、target 切换清 goal_type

## 5. 文档 + 校验 + 部署

- [ ] 5.1 运营文档：补「挂断动作」用法 + 与「客户拒绝」「勿打(do_not_call)」的区别
- [ ] 5.2 `openspec validate referee-hangup-action --strict` 通过
- [ ] 5.3 `make test-all`（common/engine/api 各 pytest + web vitest）绿
- [ ] 5.4 部署 ECS（common 先发 → engine/api/web），STATE.md 更新 alembic head（本 change 无新 migration，确认 head 不变）
- [ ] 5.5 真机验收（连真机）：配一条 hangup 规则（如裁判判 OFFENSIVE→hangup 带告别语），真拨触发，确认 AI 播告别后挂断、call_record.hangup_cause=referee_hangup、lead 不进重试/跟进队列
