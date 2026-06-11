## 0. isales-common — RoutePersonaAction.goal_type schema(Path A,实装暴露后新增)

- [x] 0.1 `schemas/jsonb/routing_rule.py` `RoutePersonaAction` 加可选 `goal_type`(max 64)+ `model_validator`(`to != "closing"` 带 goal_type → ValueError);`extra=forbid` 下使 route:closing+goal_type 合法、避免 `GET /campaigns` 500 <!-- isales-common, commit pending -->
- [x] 0.2 版本 0.8.9→0.8.10(纯 JSONB shape,**无 alembic**);consumer pin `>=0.8.x,<0.9` 已涵盖 0.8.10,无需改 pin
- [x] 0.3 测试:`test_route_closing_carries_goal_type` + `test_route_goal_type_rejected_for_non_closing`(`tests/test_tools_personas_gating.py`);`pytest` → 183 passed
- [ ] 0.4 部署:scp common `routing_rule.py` 到 ECS 各服务 release,**先于 §3 配置写入**重启 api/engine(否则旧 schema 校验 route+goal_type → 500)

## 1. isales-engine — decider route 动作补 goal_type

- [x] 1.1 `pipeline/decider.py` 的 `route` 分支(atype=="route")对称补 `goal_type=action.get("goal_type")`,与 `transition` 分支一致;`DeciderAction` 已有 `goal_type` 字段,无需改 dataclass <!-- isales-engine 59654ff -->
- [x] 1.2 单测:route:closing 携带 goal_type 的回归用例(`test_route_closing_carries_goal_type` + `test_route_without_goal_type_is_none`)加在 `tests/test_decider.py`;下游 `_select_gated_route`→`_GatedSelection.goal_type`→`append_event` 透传链路 workflow 已确认完整,decider 是唯一缺口 <!-- isales-engine 59654ff -->
- [x] 1.3 `pytest tests/test_decider.py tests/test_gating.py tests/test_run_loop.py` → 34 passed。⚠️ 1 个 pre-existing 失败 `test_gating.py::test_gate_fails_open_to_main_on_referee_timeout`(referee-timeout 时序测试,clean HEAD 同样 red,与本改动无关,已 stash 验证) <!-- pre-existing, not introduced -->`

## 2. isales-worker — 对齐 ai_reply 事件契约

- [x] 2.1 `_last_role_markers`:改读 `ai_reply` + 独立 `goal_achieved` 事件,**latch 语义**(全程扫描,达成后不被 WRAPPING_UP 的 `goal_achieved=false` ai_reply 覆盖——run_loop.py:1521-1526 实证);读不到 fail-safe `(False,None,{})` <!-- isales-worker cecfa16 -->
- [x] 2.2 `_stitch_text`:AI 侧来源 `bot_speech`→`ai_reply`,恢复摘要正文含 AI 回复 <!-- cecfa16 -->
- [x] 2.3 `base.py` docstring:契约改为「last ai_reply event + standalone goal_achieved」 <!-- cecfa16 -->
- [x] 2.4 fixture 修正:`test_summarize.py` / `test_callend.py` / `scripts/fake_call_end.py` 由 `bot_speech` 改 `ai_reply`(+ achieved 时补 goal_achieved 里程碑事件) <!-- cecfa16 -->
- [x] 2.5 回归测试:`test_markers_read_from_ai_reply` / `test_markers_latch_through_wrap_up_replies` / `test_markers_not_achieved` / `test_markers_ignore_legacy_bot_speech` <!-- cecfa16 -->
- [x] 2.6 `pytest` → 57 passed <!-- cecfa16 -->

## 3. campaign 配置(数据,依赖 §1 §2 已部署)

- [x] 3.1 ~~确定 campaign 1 的 `goal_type` 取值~~ **已定 `intent_confirmed`(泛意向)**(2026-06-11 用户拍板,见 design Open Q1)<!-- decision-only, no code -->
- [ ] 3.2 改 campaign 1 referee(`main_judge`)prompt:增补「已达成」判定语义,指示模型在客户表达明确正向意向(领试听课 / 加微信 / 约回访**任一**)时输出精确大写裸 token `SUCCESS`(engine 匹配大小写敏感、取首 token);保留原 HANGUP 语义
- [ ] 3.3 改 campaign 1 routing rule:`match:["SUCCESS"]` 的 action 由 `{type:tool, tool:hangup}` 改为 `{type:route, to:closing, then_state:WRAPPING_UP, goal_type:"intent_confirmed"}`;`HANGUP` 规则保持 `tool:hangup` 不变
- [ ] 3.4 删 campaign 1 `tools` 中 orphan 的 `end_call` 条目(零代码引用的 seed 残留)
- [ ] 3.5 若有 seed 脚本(如 `isales-api` seed)固化了 campaign 1 这些配置,同步更新 seed,避免重新 seed 时复活旧配置

## 4. isales-web — 移除 legacy 动作类型选项

- [x] 4.1 `RoutingRulesTab.vue`:legacy `transition`/`restructure` 选项改为「仅当本行已是该类型时显示」(不可新建、存量可编辑、下拉不变空);`addRule()` 默认 action 由 legacy `transition` 改现代 `route` <!-- isales-web 28a961f -->
- [x] 4.2 `types/campaign.ts` 的 `RoutingAction` union 保留 legacy 类型定义(后端 shim 仍执行存量规则),无需改;创建入口收口在 4.1 的 dropdown + addRule 默认值;legacy 行重选经 `onActionTypeChange` 四分支正确处理 <!-- 28a961f -->
- [x] 4.3 `vitest run`(routing/campaign 5 文件)→ 34 passed;`routingRulesTab.test.ts` addRule 默认值断言同步改为 route/closing <!-- 28a961f -->
- [x] 4.4 (Path A)`types/campaign.ts` `RoutePersonaAction` 加 `goal_type?`;`RoutingRulesTab.vue` 在 `route` 且 `to=closing` 时显示 goal_type 输入,`onRouteTargetChange` 切走 closing 清空(防 validator 422);加 `clears route goal_type` 测试;`vitest` 29 passed + `npm run typecheck` clean <!-- isales-web, commit pending -->`

## 5. spec 同步与校验

- [x] 5.1 spec delta(MODIFIED「实时目标达成判定」+ scenario「route 与 transition 动作的 goal_type 提取对称」+「worker 从 ai_reply 事件读取 goal 标记」)与实装一致
- [x] 5.2 `openspec validate fix-goal-achievement-pipeline --strict` → valid
- [x] 5.3 `make spec-validate` → PASS

## 6. 部署与真机验收

- [x] 6.1a 部署 engine(decider §1)+ worker(§2):scp `decider.py`/`mock.py`/`base.py` → ECS `/opt/isales/current`,import smoke OK,`systemctl restart isales-engine isales-worker` → 双 active、日志干净(engine `cloud_edge_grpc_server_started`+`credentials_loaded`,worker `metrics_tick_done campaigns=1`)<!-- 2026-06-11 deployed -->
- [ ] 6.1b 部署 common(§0.4):scp `routing_rule.py` → ECS api/engine release,重启 api/engine。**必须先于 6.1c 配置写入**
- [ ] 6.1c 部署 web(§4):build + rsync dist → `/var/www/isales-web` + nginx reload
- [ ] 6.2 mac 真机/QA 拨一通走「成功」路径的电话,验证链路:transcript 出 `ai_reply{goal_achieved:true,goal_type:X}` + 独立 `goal_achieved` 事件
- [ ] 6.2 mac 真机/QA 拨一通走「成功」路径的电话,验证链路:transcript 出 `ai_reply{goal_achieved:true,goal_type:X}` + 独立 `goal_achieved` 事件
- [ ] 6.3 验证 worker 落 `call_summary.goal_achieved=true, goal_type=X`,且摘要正文含 AI 回复
- [ ] 6.4 验证 lead 进 `COMPLETED`(referee_hangup 路径 goal_done→COMPLETED;或 wrap_up_completed 正常挂断路径 goal_achieved→COMPLETED)
- [ ] 6.5 验证 `/analytics/goal-rate` 返回非 0
- [ ] 6.6 回写 STATE.md / 相关 root 文档(若部署状态有变),更新本 tasks.md 勾选 + commit-sha 备注

## 7. 收口

- [x] 7.1 代码 4 仓 commit & push 完成:engine `59654ff` / worker `cecfa16` / web `28a961f` / meta `a6ebf1d`(均 push origin main)。campaign 配置(§3)为 prod DB,未提交(seed 若存在再随 §3 同步)
- [x] 7.2 `make test-all`:worker 57 ✓ / web 88 ✓ / common 181 ✓ / telephony 345 ✓;engine 406 passed(1 pre-existing `test_gate_fails_open_to_main_on_referee_timeout`,clean HEAD 同 red);api 2 + scheduler 3 失败=**redis-steal 环境 flake**(两仓我未触碰、git clean,当前 redis 有 3 个 BLPOP client 偎队列,见 [[feedback_legacy_macos_deploy_steals_redis]])。**本改动零新增失败**
- [ ] 7.3 `openspec validate --strict` 后准备 archive(`/opsx:archive fix-goal-achievement-pipeline`)——待 §3 配置 + §6 真机验收完成后
