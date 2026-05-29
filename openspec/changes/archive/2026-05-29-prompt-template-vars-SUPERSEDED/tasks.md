## 1. prompt_builder.py：substitute 函数 + PromptVars

- [x] 1.1 在 `isales-engine/isales_engine/pipeline/prompt_builder.py` 新增 `@dataclass(frozen=True) class PromptVars`，含 5 字段：`role_prompt: str` / `campaign_name: str` / `lead_name: str` / `lead_phone: str` / `lead_custom_data: str`（全 `str` 类型，缺值用空串）
- [x] 1.2 新增 module-level constant `_KNOWN_VAR_NAMES: frozenset[str]` = 上述 5 个变量名集合
- [x] 1.3 新增 `def _substitute(content: str, vars: PromptVars, *, source: str, source_id: int | None = None) -> str`，内部用 `string.Template(content).safe_substitute(asdict(vars))`；替换后用正则 `r"\$\{(\w+)\}|\$(\w+)\b"` 扫描残留占位符，对每个未在 `_KNOWN_VAR_NAMES` 的 var name 打 `logger.warning("prompt_template: unknown var $%s in %s id=%s, preserved literal", var, source, source_id)`；返回替换后字符串
- [x] 1.4 module 顶部加 `logger = logging.getLogger(__name__)`（如尚未存在）
- [x] 1.5 在 `__all__` 或文件末尾导出 `PromptVars` / `_substitute`（`_substitute` 模块内可见即可，给 runtime_config 用绝对路径 import）
- [x] 1.6 增加渲染辅助 `def _render_lead_custom_data(custom_data: dict[str, Any]) -> str`：把 dict 渲染成 `k=v, k=v` 文本（沿用现有 `_render_lead_info` 的格式），空 dict 返回空串

## 2. runtime_config.py：load 时一次性替换

- [x] 2.1 `isales-engine/isales_engine/runtime_config.py` import `PromptVars`, `_substitute` from `isales_engine.pipeline.prompt_builder`
- [x] 2.2 在 `load_runtime_config` 内、`role_configs` 已查到、`pv_by_id` 已构造之后，先构造 `roles_raw` —— 取所有 `kind == ROLE` 的 RoleConfig 按 `id` 升序，每个的 `pv.content`（原文，未替换）作为 raw_role_prompts 列表；`primary_role_prompt = raw_role_prompts[0] if raw_role_prompts else ""`，N=0 时 WARN `logger.warning("prompt_template: campaign id=%s has 0 roles, ${role_prompt} will be empty", campaign.id)`
- [x] 2.3 构造 `lead_name = (lead.name if lead else request.lead.name) or ""`，`lead_phone = request.lead.phone`，`lead_custom_raw = (lead.custom_data if lead else dict(request.lead.custom_data)) or {}`，`lead_custom_str = _render_lead_custom_data(lead_custom_raw)`
- [x] 2.4 构造两个 PromptVars 实例：`vars_for_role`（`role_prompt=""`，其余正常）+ `vars_for_judge_polish`（`role_prompt=primary_role_prompt`，其余正常）
- [x] 2.5 改造 `_spec_for(rc)` 不直接返回 raw `pv.content`；改为在 `RoleSpec` / `JudgeSpec` / `PolishSpec` 构造时调 `_substitute(pv.content, vars_for_role if rc.kind==ROLE else vars_for_judge_polish, source=rc.kind, source_id=rc.id)`，结果赋给 `system_prompt`
- [x] 2.6 role 内自指 `${role_prompt}` 的特殊 WARN：在 vars_for_role 阶段，因为 `role_prompt=""`，safe_substitute 直接替换为空串；同时在 `_substitute` 函数内检测 `source=="role"` 且 `content` 含 `${role_prompt}` 时额外打 `logger.warning("prompt_template: ${role_prompt} self-referenced inside role id=%s, replaced with empty", source_id)`

## 3. 单元测试

<!-- 实装挪到 isales-engine/tests/test_prompt_template_vars.py (独立文件) 而非 test_prompt_builder.py -->
- [x] 3.1 在 `isales-engine/tests/test_prompt_template_vars.py`（独立新文件）增加 `class TestPromptTemplateVars`
- [x] 3.2 case：5 个已知变量全替换 — 输入含 5 个 `${var}` 的 prompt + 完整 PromptVars → 输出全替换后字面，无 WARN
- [x] 3.3 case：未知变量保留 — `"hello ${unknown_var}"` + 任意 vars → 输出保留 `"hello ${unknown_var}"`，期望 WARN log 1 次（用 `caplog` fixture）
- [x] 3.4 case：role 内 `${role_prompt}` 自指 — `_substitute("you are ${role_prompt}", vars_for_role, source="role", source_id=1)` → `"you are "`，期望 self-reference WARN log
- [x] 3.5 case：judge 拿到 `${role_prompt}` — `_substitute("scenario: ${role_prompt}", vars_for_judge_polish, source="judge", source_id=5)` → `"scenario: <primary role prompt>"`，无 WARN
- [x] 3.6 case：`${lead_custom_data}` 渲染 — `dict={"city":"上海","age":30}` → `"city=上海, age=30"`；空 dict → 空串
- [x] 3.7 case：legacy `${roleUser}` / `${roleAssistant}` 字面 — 输入 `"你${roleUser}好"` → 输出保留 `"你${roleUser}好"` + WARN（确保 PG 历史数据不炸）
- [x] 3.8 case：`$var` 短形式也支持 — `"phone is $lead_phone"` + vars → `"phone is 13301035545"`
- [x] 3.9 跑 `make test-all PYTEST_ARGS="-k prompt_template"`，全绿 — 7 passed

## 4. 集成测试：load_runtime_config 端到端

- [x] 4.1 在 `isales-engine/tests/test_runtime_config.py`（独立新文件）增加 `test_load_runtime_config_substitutes_role_prompt_into_judge`
- [x] 4.2 fixture：真 PG (`clean_engine` + `sessionmaker_`) 插 Campaign + RoleConfig (ROLE + JUDGE) + PromptVersion 两条 (`"我是销售员小王"` / `"销售场景：${role_prompt}。判断 candidate"`) + Lead，与本地 isales_engine_test 库
- [x] 4.3 assert：返回的 `RuntimeConfig.pipeline.judges[0].system_prompt == "销售场景：我是销售员小王。判断 candidate"`
- [x] 4.4 assert：`RuntimeConfig.pipeline.roles[0].system_prompt == "我是销售员小王"`（role 内不含 `${role_prompt}` → 不替换、不动）
- [x] 4.5 跑 `make test-all PYTEST_ARGS="-k test_load_runtime_config"`，全绿 — 1 passed; 全套 275/280 (5 pre-existing TTS volcengine 失败与本 change 无关)

## 5. PG 数据迁移（手工 SQL）

- [ ] 5.1 ssh 到 ECS `121.89.85.150`：`ssh -i ~/codes/isales-4.pem root@121.89.85.150`
- [ ] 5.2 在 PG 上 `SELECT id, content FROM prompt_version WHERE id IN (3) \gx` 保存旧 content 到 tasks.md inline 注释（备份）
- [ ] 5.3 把 judge prompt（id=3）重写为新版本：以 `# 销售场景\n${role_prompt}\n\n# 你的任务\n上面是销售 AI 的角色描述。系统会把销售 AI 准备说给客户的下一句话给你审查...`为基底，由用户拍板最终文案
- [ ] 5.4 跑 `UPDATE prompt_version SET content = '<新文案>' WHERE id = 3;`
- [ ] 5.5 验证 `SELECT id, content FROM prompt_version WHERE id = 3;` 内容含 `${role_prompt}` 字面
- [ ] 5.6 把执行的 SQL（旧值 + 新值）追加到本 task 的 inline 注释，便于 archive 时溯源

## 6. ECS 部署 + smoke 验证

- [ ] 6.1 commit 代码改动到 `isales-engine` 仓 `dingrtc-migration-cloud` 分支
- [ ] 6.2 push 到 origin
- [ ] 6.3 ssh ECS → `cd /opt/isales-engine && git pull && systemctl restart isales-engine`
- [ ] 6.4 `journalctl -u isales-engine -n 20 -f` 看启动 log，无 import error / unknown_var 异常 WARN
- [ ] 6.5 mac dev DingRTC 真拨号（按 memory `project_macos_dev_path` 的"一行启动"命令）
- [ ] 6.6 拨通后说一句日常话术，听 AI 回复 — 期望听到真正 personalized 销售话术（**不是** "测试测试"）
- [ ] 6.7 在 ECS engine log 上 grep `judge_result`，期望见 `passed=true` 至少出现一次（替代之前每轮 `passed=False reason="...无关内容"`）
- [ ] 6.8 在 engine log 上 grep `prompt_template:`，确认 unknown_var WARN 不爆发（健康基线：0 或仅 legacy `${roleUser}` 类）

## 7. 收尾

- [ ] 7.1 跑 `openspec validate prompt-template-vars --strict` 全绿
- [ ] 7.2 在 meta-repo `~/codes/isales` commit tasks.md 进度回写（每个 task 旁加 `<!-- <commit-sha> 备注 -->`）
- [ ] 7.3 meta-repo + isales-engine 子仓 push origin
- [ ] 7.4 用户确认 smoke 绿后，进入 archive 流程 (`/opsx:archive prompt-template-vars`)
