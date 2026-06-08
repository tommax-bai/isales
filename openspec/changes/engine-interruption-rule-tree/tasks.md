# Tasks — engine-interruption-rule-tree

> 进度回写约定：完成的 task 用 `- [x]` + 行尾 HTML 注释 `<!-- commit-sha 备注 / PR# / 偏离说明 -->`。代码改动落对应 sub-repo，进度回写本 meta-repo。

## 1. isales-common — 规则树 schema + campaign 列

- [ ] 1.1 在 `isales-common/isales_common/schemas/jsonb/` 新增 `interruption_rule.py`：递归 Pydantic discriminated-union（按 `type` 判别）——叶子 `keyword`(values:list[str], match:Literal["contains","exact"]="contains")/`length`(value:int)/`duration`(value_ms:int)/`regex`(pattern:str)/`split_by_delimiter`(delimiters:list[str])/`none`；组合 `and`(rules:list)/`or`(rules:list)/`not`(rule:single)。带深度/节点上限校验（design Q1：深度≤8、节点≤64）+ regex pattern 长度上限（≤128）
- [ ] 1.2 `isales-common/isales_common/models/campaign.py`：`Campaign` 模型加 `interruption_rules: Mapped[dict | None]`（JSONB, nullable, default None）
- [ ] 1.3 `isales-common/isales_common/schemas/campaign.py`：Pydantic Campaign schema 加 `interruption_rules: InterruptionRule | None = None`
- [ ] 1.4 alembic migration（`isales-common/alembic/versions/`）：给 `campaign` 加 `interruption_rules JSONB NULL` 列（**纯 schema-additive，不回填**，存量行保持 NULL → 引擎从 legacy 列合成默认树，见 design D4）。**commit 前跑 `alembic heads` / `alembic history` 确认 revision id 不撞**（手编滚动 id，见 [[feedback_alembic_revision_id_collision]]）
- [ ] 1.5 去 low_confidence 文档措辞：`pipeline_trace.py` 注释 + `schemas/jsonb/routing_rule.py` 的 `RestructureSource` 注释（low_confidence 那段说明删除/改写）
- [ ] 1.6 bump `isales-common` version；isales-engine / isales-api 升级 pin
- [ ] 1.7 isales-common pytest 全绿（含 1.1 schema 的合法/非法/超深/超长 case）

## 2. isales-engine — 规则树模块 + factory

- [ ] 2.1 `isales-engine/isales_engine/realtime/interruption_rules.py`（新文件，port voxen `core/interruption/`）：`RuleInput(text:str, elapsed_ms:int)`、`RuleVerdict`、`Rule` 协议 `should_interrupt(ctx)->RuleVerdict`；叶子类 Keyword/Length/Duration/Regex/SplitByDelimiter/None + 组合类 And/Or/Not（短路 + reason provenance 拼接，对齐 voxen）
- [ ] 2.2 同文件 `build_rule(config: dict | None) -> Rule`：递归构建；`None` / `{"type":"none"}` → NoneRule；未知 type / 结构错抛明确异常（装配期 fail-fast，design D7）
- [ ] 2.3 `keyword` 叶子实现 `match="contains"|"exact"` 两模式 + trim 尾部标点（对齐 voxen `keyword_rule` TrimRight）；`duration` 用 `ctx.elapsed_ms`（iSales 语义，**不**移植 voxen timeInterval，design D3）

## 3. isales-engine — evaluate_partial 改走规则树 + runtime_config 装配

- [ ] 3.1 `realtime/interruption_detector.py`：`InterruptionConfig` 持有编译好的 `Rule`（编译一次，design D1）；`evaluate_partial(text, speech_started_ts_ms, now_ts_ms, config)` 改为构造 `RuleInput(text, elapsed_ms=now-speech_started)` 调 `config.rule.should_interrupt(...)`，返回 `InterruptionVerdict(verdict, reason=provenance)`；删 prototype 硬编码 `_MIN_TEXT_LENGTH_PROTOTYPE`
- [ ] 3.2 `runtime_config.py`：读 `campaign.interruption_rules`；非 NULL → `build_rule(...)`；NULL → 合成默认树 `AND(NOT keyword(match="exact", values=interruption_whitelist), length(value=2), duration(value_ms=interruption_min_duration_ms))`（design D4），编译进 `InterruptionConfig`
- [ ] 3.3 更新 `interruption_detector.py` 模块 docstring（双/三条件 → 可组合规则树）

## 4. isales-engine — 吸收 text-length-gate（VAD-source cancel deprecate）

- [ ] 4.1 `run_loop.py::_vad_monitor`：删 `speaking_task.cancel()` + `source="vad"` transcript 写入；保留 `session.vad_voice_active_ms` mirror（corroboration）；加注释指向本 change + 标注 corroboration mirror 的移除触发条件（design D5）
- [ ] 4.2 加 `logger.info` 记录 vad_monitor 仍跑但不再 cancel（ops 可验证）

## 5. isales-engine — 删 low_confidence 死分支

- [ ] 5.1 `pipeline/decider.py`：删「无规则命中 → 主裁判 confidence<阈值 → restructure(last_reply, trigger=low_confidence)」整段（现 `decider.py:108-124`）；无命中统一 fail-open continue
- [ ] 5.2 `streaming/types.py`：删 `FAILOPEN_LOW_CONFIDENCE` 常量 + `effective_category` 里返回它的分支
- [ ] 5.3 grep 清残留：`run_loop.py` / `decider.py` 注释里 low_confidence 措辞改写（restructure_trigger 字段保留，仅去 "low_confidence" 取值）

## 6. isales-engine — 单测

- [ ] 6.1 `tests/test_interruption_rules.py`（新）：各叶子（keyword contains/exact + 尾标点 trim、length、duration、regex、split_by_delimiter、none）+ 组合（and 短路、or 短路、not、嵌套）单测
- [ ] 6.2 `tests/test_interruption_detector.py`：**默认树对拍**——同一批 ASR partial 输入，默认树 verdict MUST 等于历史「whitelist 精确 → 字数≥2 → 时长」序列（逐 case 对拍，证 design D4 等价）
- [ ] 6.3 `tests/test_realtime_interruption.py`：调整 `_vad_monitor` 不再 cancel 的断言（vad 仅 mirror voice_active_ms）
- [ ] 6.4 `tests/`（decider）：加 case 证「无规则命中 + 主裁判任意 confidence → continue（不再 restructure low_confidence）」
- [ ] 6.5 `cd ../isales-engine && .venv/bin/python -m pytest -q` 全绿

## 7. isales-api — 规则树校验 endpoint

- [ ] 7.1 campaign 写入/更新路径校验 `interruption_rules`：复用 common schema（1.1）+ 深度/节点/regex 长度上限；非法返回 422 带具体错因
- [ ] 7.2 api 单测：合法树通过 / 非法 type / 超深 / regex 超长 全覆盖

## 8. ECS 部署

- [ ] 8.1 ssh ECS `alembic upgrade head`（加 `interruption_rules` 列，存量行 NULL）
- [ ] 8.2 升级 isales-common wheel + scp engine 改动（`interruption_rules.py` / `interruption_detector.py` / `runtime_config.py` / `run_loop.py` / `decider.py` / `streaming/types.py`）到 `/opt/isales/current/isales-engine/...`（走 scp，见 [[feedback_ecs_deploy_scp]]）
- [ ] 8.3 `systemctl restart isales-engine`；journalctl 验证 `isales_engine_started` + 无 import/config 错

## 9. mac dev smoke 验证

- [ ] 9.1 默认树 campaign 复跑 #136（mac dev-no-modem 真 mic 多轮）：AI 长回应 `interrupted=false`、0 误触发（证默认树等价 + VAD deprecate 生效）
- [ ] 9.2 配一棵显式规则树（含 keyword contains + regex + and/or/not）复测：验证子串语气词忽略 + 正则触发 + 嵌套组合按预期 trigger/ignore

## 10. isales-web — 打断规则编辑面（分阶段，可在 engine 上线后单独推进）

- [ ] 10.1 场景配置加「打断规则」编辑入口：and/or/not + 各叶子组合 UI；未配置展示「使用默认规则」+ 一键基于默认树开始编辑
- [ ] 10.2 保存前调 7.1 校验 endpoint；失败就地提示具体错因；文案对齐 STYLE_GUIDE（不暴露引擎字段名，见 [[feedback_webui_style_guide]]）
- [ ] 10.3 web vitest 绿

## 11. 收尾 — SUPERSEDE 吸收的 change + validate + archive 准备

- [ ] 11.1 `interruption-detection-text-length-gate`：proposal.md 顶部加 SUPERSEDED block 引用本 change（说明其意图已被吸收），移到 `openspec/changes/archive/<date>-interruption-detection-text-length-gate-SUPERSEDED/`
- [ ] 11.2 `openspec validate engine-interruption-rule-tree --strict` 通过
- [ ] 11.3 全 task 完成 + 三端实证后 → 走 `/opsx:archive`（合并 spec delta 到 `openspec/specs/`）
