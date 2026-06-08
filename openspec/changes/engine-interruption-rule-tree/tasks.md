# Tasks — engine-interruption-rule-tree

> 进度回写约定：完成的 task 用 `- [x]` + 行尾 HTML 注释 `<!-- commit-sha 备注 -->`。代码改动落对应 sub-repo，进度回写本 meta-repo。
> 实装 session 2026-06-08：common `d9df098` / engine `c6e5d1e` / api `9e1dfe7` / web `45e6a4c`。

## 1. isales-common — 规则树 schema + campaign 列

- [x] 1.1 `schemas/jsonb/interruption_rule.py`：递归 discriminated-union 规则树 + 深度/节点/regex 上限 + `validate_interruption_rule` <!-- d9df098 -->
- [x] 1.2 `models/campaign.py`：加 `interruption_rules` JSONB nullable 列 <!-- d9df098 -->
- [x] 1.3 `schemas/campaign.py`：CampaignBase + CampaignUpdate 加 `interruption_rules` <!-- d9df098 -->
- [x] 1.4 alembic `c9d0e1f2a3b4`（down=`b8c9d0e1f2a3`）：add interruption_rules + drop primary_referee_label；单一 head 已确认 <!-- d9df098 -->
- [x] 1.5 去 low_confidence 文档措辞：`pipeline_trace.py` + `routing_rule.py` RestructureSource 注释 <!-- d9df098 -->
- [x] 1.6 bump isales-common 0.8.1→0.8.2；engine/api pin 同步（engine `>=0.8.2,<0.9`，api 已 `>=0.8,<0.9`） <!-- d9df098 / c6e5d1e -->
- [x] 1.7 isales-common pytest 全绿（185 passed） <!-- d9df098 -->
- [x] 1.8 拔 `primary_referee_label`（design D8）：model + schemas.campaign×2 + schemas.pipeline + 2 测试 <!-- d9df098 -->

## 2. isales-engine — 规则树模块 + factory

- [x] 2.1 `realtime/interruption_rules.py`：RuleInput/RuleVerdict/Rule + 叶子 + 组合（短路 + reason provenance） <!-- c6e5d1e -->
- [x] 2.2 `build_rule(dict|None)` 递归构建 + fail-fast；`default_rule(...)` 合成默认树 <!-- c6e5d1e -->
- [x] 2.3 keyword `contains`(子串,trim 尾标点)/`exact`(legacy whitelist 等价)；`duration` 用 elapsed_ms（不移植 voxen timeInterval） <!-- c6e5d1e -->

## 3. isales-engine — evaluate_partial 改走规则树 + runtime_config 装配

- [x] 3.1 `interruption_detector.py`：InterruptionConfig 持 `rule`；evaluate_partial 跑规则树；删 prototype 硬编码 <!-- c6e5d1e -->
- [x] 3.2 `runtime_config.py`：非 NULL→build_rule，NULL→default_rule（从 legacy whitelist+min_duration 合成） <!-- c6e5d1e -->
- [x] 3.3 更新 detector 模块 docstring（→ 可组合规则树） <!-- c6e5d1e -->

## 4. isales-engine — 吸收 text-length-gate（VAD-source cancel deprecate）

- [x] 4.1 `run_loop._vad_monitor`：删 cancel + source=vad transcript（清死代码）；保留 vad_voice_active_ms mirror；去已不用的 interruption_cfg param <!-- c6e5d1e -->
- [x] 4.2 docstring 收口成 mirror-only 角色说明（含 mirror 移除触发条件） <!-- c6e5d1e -->

## 5. isales-engine — 删 low_confidence 死分支 + 拔 primary_referee_label

- [x] 5.1 `decider.py`：删低置信兜底整段 + 去 primary_referee_label 形参；无命中统一 fail-open continue <!-- c6e5d1e -->
- [x] 5.2 `streaming/types.py`：删 FAILOPEN_LOW_CONFIDENCE + trace_category 的该分支（保留通用 confidence floor） <!-- c6e5d1e -->
- [x] 5.3 清残留 primary_referee_label：run_loop(decider 调用) + runtime_config + prompt_builder PipelineConfig <!-- c6e5d1e -->
- [x] 5.4 测试去引用：test_decider / test_run_loop <!-- c6e5d1e -->

## 6. isales-engine — 单测

- [x] 6.1 `tests/test_interruption_rules.py`：叶子 + 组合（短路/嵌套）+ factory + default_rule（18 case） <!-- c6e5d1e -->
- [x] 6.2 `tests/test_realtime_detectors.py`：默认树对拍历史行为（whitelist/length/duration）+ 单字 length 过滤 <!-- c6e5d1e -->
- [x] 6.3 `tests/test_realtime_interruption.py`：InterruptionConfig 改用 default_rule；vad 不再 cancel <!-- c6e5d1e -->
- [x] 6.4 test_decider：无命中+任意 confidence → continue（不再 low_confidence restructure） <!-- c6e5d1e -->
- [x] 6.5 engine 全套 pytest 全绿（399 passed） <!-- c6e5d1e -->

## 7. isales-api — 规则树校验 + 拔 primary_referee_label

- [x] 7.1 campaign create/update 校验 `interruption_rules` 深度/节点（422 interruption_rule_invalid）；结构/regex 由 common schema 把关 <!-- 9e1dfe7 -->
- [x] 7.2 api 单测全绿（128 passed；2 个 redis-queue 测试为已知环境失败 stale blpop/db 错配，与本 change 无关） <!-- 9e1dfe7 -->
- [x] 7.3 拔 primary_referee_label：schemas + campaigns router + routing_validation + role_configs 删除保护；test 去引用 <!-- 9e1dfe7 -->

## 8. ECS 部署

- [ ] 8.1 ssh ECS `alembic upgrade head`（加 interruption_rules 列 + drop primary_referee_label；存量行 NULL）— **drop_column 在共享 RDS 上不可逆，待用户确认时机**
- [ ] 8.2 升级 common wheel + scp engine 改动到 `/opt/isales/current/isales-engine/...`（scp 覆盖，见 [[feedback_ecs_deploy_scp]]）
- [ ] 8.3 `systemctl restart isales-engine` + journalctl 验证无 import/config 错

## 9. mac dev smoke 验证

- [ ] 9.1 默认树 campaign 复跑 #136（真 mic 多轮）：AI 长回应 interrupted=false、0 误触发（证默认树等价 + VAD deprecate）
- [ ] 9.2 配显式规则树（keyword contains + regex + and/or/not）复测：子串语气词忽略 + 正则触发 + 嵌套组合

## 10. isales-web — 打断规则编辑面（分阶段）

- [ ] 10.1 场景配置加「打断规则」可组合编辑界面（and/or/not + 各叶子）— **phased follow-on，本 change 只定 schema/契约**
- [ ] 10.2 保存前调 7.1 校验 endpoint；文案对齐 STYLE_GUIDE — **phased follow-on**
- [x] 10.3 拔 primary_referee_label：types/campaign.ts + RoutingRulesTab + ToolsTab <!-- 45e6a4c -->
- [x] 10.4 web typecheck + vitest 绿（56 passed） <!-- 45e6a4c -->

## 11. 收尾 — SUPERSEDE 吸收的 change + validate + archive 准备

- [x] 11.1 `interruption-detection-text-length-gate` 标 SUPERSEDED block + 移到 `archive/2026-06-08-interruption-detection-text-length-gate-SUPERSEDED/` <!-- meta 本次 -->
- [x] 11.2 `openspec validate engine-interruption-rule-tree --strict` 通过 <!-- meta 本次 -->
- [ ] 11.3 全 task 完成 + 三端实证（§8/§9）后 → `/opsx:archive`（合并 spec delta 到 specs/）
