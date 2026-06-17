## 1. isales-common — opt-in flag column

- [ ] 1.1 `models/campaign.py` 收尾列块新增 `wrap_up_referee_enabled: Mapped[bool]`（NOT NULL, `server_default="false"`, default False）
- [ ] 1.2 `schemas/campaign.py` CampaignBase 加 `wrap_up_referee_enabled: bool = False`；CampaignUpdate 加 `bool | None = None`
- [ ] 1.3 新建 alembic migration ADD COLUMN（**commit 前 `alembic heads` 确认不撞**，`down_revision='b3d5f7a9c1e2'`）
- [ ] 1.4 `pyproject.toml` 0.8.21→0.8.22 + CHANGELOG；确认消费方 pin 容纳

## 2. isales-api — ⚠️ 手维护镜像必改（Slice 1 踩过 hotfix 673697a）

- [ ] 2.1 `isales_api/schemas.py` 的 `CampaignNestedUpdate`（`extra="forbid"`、不继承 CampaignBase）补 `wrap_up_referee_enabled: bool | None = None`，否则 web PATCH 带该字段 → 422。`CampaignNestedCreate` 继承 CampaignBase 自动带、无需改
- [ ] 2.2 跑 api campaign 测试确认 PATCH/POST 接受新字段（除已知 redis-steal pre-existing 失败外全绿）

## 3. isales-engine — built-in wrap-up referee constants

- [ ] 3.1 引擎模块级常量：`WRAP_UP_REFEREE_PROMPT`（内建 system prompt：判客户这句有无需 AI 回答的实质新问题→只输出 `有问题`/`无问题`；无问题=附和/客套/同意结束/无内容）+ `WRAP_UP_HANGUP_CATEGORIES = frozenset({"无问题"})`
- [ ] 3.2 `wrapup/manager.py` `WrapUpConfig` 加 `referee_enabled: bool`
- [ ] 3.3 `runtime_config.py` 装配 `WrapUpConfig.referee_enabled = campaign.wrap_up_referee_enabled`

## 4. isales-engine — bypass referee in _gated_wrap_up_turn

- [ ] 4.1 `_gated_wrap_up_turn`：若 `config.wrap_up.referee_enabled` → `_play_streaming` **之前** `ref_task = asyncio.create_task(run_referee(session, user_text, recent_dialog_rounds(session.dialog_history), <built-in RefereeSpec>, providers.llm))`（与播放并行）。收尾回复照常播、**不门控**
- [ ] 4.2 `not played`（barge-in）路径：若 `ref_task` 存在则 `ref_task.cancel()` 再 `return Directive.CONTINUE`（防泄漏 + 不挂正在提问的客户）
- [ ] 4.3 `played` 后：`try: result = await asyncio.wait_for(ref_task, config.pipeline.referee_timeout_ms/1000); cat = result.category` `except (asyncio.TimeoutError, Exception): ref_task.cancel(); cat = None`（**绝不裸 await、绝不 else→挂**）
- [ ] 4.4 `cat in WRAP_UP_HANGUP_CATEGORIES` → 复用 hangup→END：设 `HangupCause.REFEREE_HANGUP` + `transition_to(CallStatus.END, reason="wrap_up_referee_hangup", force=True)` + `append_event("hangup", reason="wrap_up_referee_hangup", initiated_by="ai")` + `return Directive.RETURN`；否则落现有 `wrap_up_round_count += 1` + `evaluate_wrap_up`
- [ ] 4.5 裁判跑了就把 `result` 写进本轮 pipeline_trace 的 `referee_results`（替代当前恒 `[]`）；加注释写明「场景 + fail-open 方向 + 移除条件」

## 5. isales-web — opt-in toggle

- [ ] 5.1 `views/Campaigns/Tabs/WrapUpTab.vue` 加「收尾裁判（客户无实质问题即挂）」`el-switch` 绑 `wrap_up_referee_enabled`
- [ ] 5.2 `types/campaign.ts` CampaignBase 加 `wrap_up_referee_enabled: boolean` + defaults 对象

## 6. Tests

- [ ] 6.1 单元（evaluate / referee parse）：裁判输出 `无问题` → 命中挂断集合；`有问题` / 空 / None → 不命中
- [ ] 6.2 集成：`wrap_up_referee_enabled=true`，进 wrap-up → 客户应一句「嗯好的」（mock 裁判判 `无问题`）→ 断言 `hangup` `reason="wrap_up_referee_hangup"` + `hangup_cause=REFEREE_HANGUP` + 收尾回复仍播出（played）+ 未多播额外话
- [ ] 6.3 集成：客户问实质问题（mock 判 `有问题`）→ 不挂、继续简化管线（落计数器）
- [ ] 6.4 集成 fail-open：裁判超时/异常 → 不挂、落计数器兜底
- [ ] 6.5 集成 barge-in：客户打断收尾回复（`not played`）→ ref_task 取消、CONTINUE、不挂
- [ ] 6.6 回归：`wrap_up_referee_enabled=false`（默认）→ 收尾轮行为与 Slice 1 一致（不 spawn 裁判、`referee_results=[]`、静默挂断+计数器照常）
- [ ] 6.7 `ISALES_ENGINE_STRICT_TRANSCRIPT=1` 全量 + `make test-all`（engine/api venv 重装 common 0.8.22 后）；甄别 pre-existing（engine gate timeout / api redis-steal）

## 7. 部署 + 验收

- [ ] 7.1 部署：common scp + `alembic upgrade head`（列 server_default false 对在途安全）→ engine scp+restart → **api scp+restart**（拾 `CampaignNestedUpdate` 镜像）→ web build+nginx reload；部署后 `/openapi.json` 探针验 `CampaignNestedUpdate` 含 `wrap_up_referee_enabled`；更新 `deploy/cloud/STATE.md`
- [ ] 7.2 真机/真通话验收（按需，可豁免）：开 `wrap_up_referee_enabled` 的 campaign，进收尾后客户应一句无实质内容 → 引擎提前挂、reason=`wrap_up_referee_hangup`、`/calls` 不 500
- [ ] 7.3 本文件 `<!-- commit-sha -->` 回写 PR#/commit/偏离
