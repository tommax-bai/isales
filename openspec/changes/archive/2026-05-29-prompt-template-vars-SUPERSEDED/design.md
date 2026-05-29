## Context

iSales engine 的三层 AI 管线（role / judge / polish）当前从 PG 的 `prompt_version.content`
字段加载 system prompt 原文，按字面送入 LLM。没有变量替换机制。

2026-05-28 真拨号 session 实证了一个由此引发的概念错位：judge prompt 概念是"答案相关性
分类器"（input 是否跟 my dialog 相关），而 orchestrator 实际是把销售 AI 生成的 candidate
喂给它做"销售场景下能不能发"评判。judge 因缺销售场景上下文判 `passed=false`，所有候选
被 reject → 走 `default_replies`（"测试测试"）fallback。

修法的本质方向用户已在 handoff 里拍板：用 `${role_prompt}` 把销售角色的 system prompt 注
入 judge / polish 的 system prompt，让它们承接销售场景。这一刻把"模板变量"作为机制本身
落到 spec 里，避免每次新需求来都临时打补丁。

**当前代码状态（2026-05-28 ff776a8）**：
- `prompt_builder.py` 已经在 system prompt 末尾追加 `ROLE/JUDGE/POLISH_OUTPUT_SCHEMA_SUFFIX`
  解决 JSON schema 强约束问题
- `runtime_config.load_runtime_config` 已把 campaign、lead、role_config、prompt_version
  全查到位，把 `pv.content` 直接赋值给 `RoleSpec/JudgeSpec/PolishSpec.system_prompt`
- 没有 substitution 步骤 — 这正是要插入的位置

**约束**：
- PG `prompt_version.content` 是历史长存数据；不能要求用户立刻迁移所有占位符
- engine hot path 性能敏感（每通对话循环多次调用 LLM）；substitution 不能放在 hot path
- 已有 `OUTPUT_SCHEMA_SUFFIX` 机制必须保留，substitution 与 suffix 的先后顺序要清晰

## Goals / Non-Goals

**Goals:**

- 让 PG-stored prompt 支持 `${var}` 占位符，最小变量集 5 个（`role_prompt` / `campaign_name`
  / `lead_name` / `lead_phone` / `lead_custom_data`）够覆盖 judge 概念错位修法 + 常见
  campaign 个性化需求
- 替换语法使用 Python 标准库 `string.Template`，避免引入 jinja2 / mustache 等外部 DSL
- 替换发生在 `RuntimeConfig.load` 一次，build hot path 零增量
- 未知变量保留字面 + WARN（不 raise，不隐式默认值）—— 历史 PG 数据安全 + 未来变量名安全
- spec 化机制本身，让 isales-web 后续给 prompt 编辑器加 "available variables" UI 有清晰
  合约依据

**Non-Goals:**

- **不**实装条件 / 循环 / 嵌套 / 函数调用等高级模板语法（v1 故意保持最小）
- **不**改 PG schema（`prompt_version.content` 类型不变）
- **不**改 `call_record.prompt_versions` 快照格式（仍只存 `prompt_version_id`，原文从 PG 取）
- **不**做 isales-web 的编辑器 UI（"variable picker"留到 web-admin-* 后续 change）
- **不**做 N-role > 1 时 `${role_prompt}` 的高级路由（per-judge-call 取对应 source role
  的 prompt）—— v1 简单取 `roles[0]`，详见 § Decisions
- **不**给 role.system_prompt 内 `${role_prompt}` 自指做特殊处理（替换为空串 + WARN
  足够；不增加循环检测复杂度）
- **不**重写已有 OUTPUT_SCHEMA_SUFFIX 机制 — 它正交且必要

## Decisions

### 决策 1：替换时机 = `RuntimeConfig.load_runtime_config` 一次

**选择**：`load_runtime_config` 内构造 `PromptVars` 后，对 role / judge / polish 三类
spec 的 `.system_prompt` 字段做一次性替换。之后 `prompt_builder.build_*_messages` 拿到的
是已替换的字面文本。

**备选**：
- A. 在 `build_*_messages` 内每次调用都替换——hot path 多一次 string scan + dict lookup，
  N 角色 × M 裁判 × 多轮对话累积代价非零；且每次调用的 vars 完全相同没意义
- B. 在 `prompt_version` 入 PG 时静态替换——但 lead/campaign 是 per-call 的，PG 落库时
  还没这些数据；不可行

**结论**：选 load 时一次替换。`PromptVars` 由 `Campaign` + `Lead` + `RoleSpec[0]` 在
`load_runtime_config` 内组装；之后 `RoleSpec/JudgeSpec/PolishSpec.system_prompt` 全是已
替换的字面字符串。

**对 N-role 的影响**：`${role_prompt}` 替换源是 `roles[0].system_prompt`——在 N=1（v1 常态）
下完全合理；N>1 时 judge / polish 拿到的是"主角色"上下文，**未来需要细化时再起新 change**
（per-candidate 替换需要把 substitution 推迟到 build_*_messages 阶段，properly 实现需要把
source role 传到 build_judge_messages，是较大改动；当前不需要）。

### 决策 2：占位符语法 = `string.Template` 的 `${var}` / `$var`

**选择**：用 Python 标准库 `string.Template`，仅支持 `${var}` 与 `$var` 两种语法（不含
条件 / 循环 / 自定义过滤器）。

**备选**：
- A. jinja2 —— 功能过剩；引入新 pip 依赖（engine 当前不依赖 jinja2）；语法更易冲突
  （`{{ }}` 容易跟 LLM 输出的 JSON 模板混淆）
- B. 自研 mini-DSL —— NIH，代价高
- C. `str.format` `{var}` —— 跟 LLM 输出 JSON schema 的 `{...}` 大括号会大量冲突；
  必须双花括号转义，PG 用户编辑体验差

**结论**：选 `string.Template`。`$` 符号在中文 LLM prompt 里出现频率极低，冲突风险最小；
是 stdlib 零依赖；语义最小。

### 决策 3：未知变量处理 = 保留字面 + WARN（不 raise / 不默认值）

**选择**：用 `Template.safe_substitute(mapping)`——未知变量保留 `${var}` 字面字符串原样
传给 LLM。同时在 `_substitute` 内部主动扫描 `${...}` 模式，对每个未在 vars dict 里的 key
打 WARN log（`logger.warning("prompt_template: unknown var ${%s} in prompt_version_id=%s, preserved literal", var, pv_id)`)。

**备选**：
- A. `Template.substitute()` 严格模式 —— 未知变量 raise `KeyError`。PG 历史数据含 `${roleUser}`
  这类未实装变量会全部炸；任何拼写错误也会立刻炸整个 call。安全性差。
- B. 替换成空串 —— 隐式吞 bug，用户写错变量名后无声变成空白，调试地狱（违反 feedback_avoid_multilayer_fallback）

**结论**：选 safe_substitute + WARN。字面保留对 LLM 也基本无害（LLM 看到 `${roleUser}` 当
没看见即可），WARN 在 logs 里可见性高，将来可加 isales-web 编辑器 lint。

### 决策 4：替换与 OUTPUT_SCHEMA_SUFFIX 的顺序 = **先替换、后 suffix**

**选择**：`load_runtime_config` 阶段替换 → 替换后的 `.system_prompt` 仍是 PG 原文形态（不
含 suffix）→ `build_role_messages` 在 system 字符串末尾追加 `ROLE_OUTPUT_SCHEMA_SUFFIX`，
**不**对 suffix 做替换。

**理由**：
- SCHEMA_SUFFIX 是引擎硬约束（JSON schema），不应包含用户变量
- 替换源 `${role_prompt}` 注入的内容是销售 role 的 system prompt 原文（不含 suffix），
  这样 judge / polish 看到的角色描述跟 role LLM 自己看到的语义一致
- 顺序反过来（先 suffix、后替换）会出现 `${role_prompt}` 注入时把 role 的 suffix 也带进
  judge 的 prompt 里，造成 schema 命令重叠

### 决策 5：变量集 = 最小 5 个

**选择**：
| 变量 | 来源 | 缺值处理 |
|---|---|---|
| `${role_prompt}` | `roles[0].system_prompt`（substitute 前的 PG 原文） | N=0 时空串 + WARN |
| `${campaign_name}` | `Campaign.name` | 空串（理论必有） |
| `${lead_name}` | `Lead.name`（DB） / `request.lead.name`（DialRequest） | 空串 |
| `${lead_phone}` | `request.lead.phone` | 空串 |
| `${lead_custom_data}` | `Lead.custom_data` / `request.lead.custom_data`，渲染成 `k=v, k=v` | 空串 |

**理由**：
- `${role_prompt}` 是入口任务直接需要的（修 judge 概念错位）
- `${campaign_name}` / `${lead_name}` / `${lead_phone}` 是 campaign 编辑者常见个性化需求
- `${lead_custom_data}` 兜底（Lead 有 JSONB 字段存 ad-hoc 业务数据）
- 未来需要新变量（例如 `${last_call_time}` / `${followup_count}`）单独追加，不影响合约

**故意不加**：
- `${dialog_history}` / `${last_call_summary}` —— 这些是 user message 段内容，由 `_build_user_message`
  组装，不该在 system prompt 里再重复
- `${current_time}` —— 时间相关变量需要时区策略；v1 不开
- `${wrap_up_instruction}` —— 已经在 system 末尾通过 `WRAP_UP_APPEND` 追加，不重复机制

### 决策 6：`${role_prompt}` 在 role.system_prompt 内自指 = 空串 + WARN

**选择**：当 role 自己的 prompt 含 `${role_prompt}` 时，替换为空串（避免无限循环 / 重复
内容），同时 WARN log（`logger.warning("prompt_template: ${role_prompt} self-referenced inside role prompt id=%s, replaced with empty", role.role_config_id)`）。

**实现细节**：用两段式 PromptVars——
- `_PromptVarsForRole`（role 替换时用）：`role_prompt=""`，其余正常
- `_PromptVarsForJudgePolish`（judge / polish 替换时用）：`role_prompt=roles[0].system_prompt`，
  其余正常

**理由**：直接传两个 mapping 比"先替换 role、再用替换结果替换 judge"循环逻辑简单。

## Risks / Trade-offs

**[Risk] N>1 多角色时 `${role_prompt}` 只取 `roles[0]`，其他 role 视角丢失**
→ Mitigation：v1 N=1 是常态（实际 campaign 都是单角色 PK 同一 role 多次 / 单角色生成单
candidate）；spec 文档明确"v1 取 roles[0]，N>1 时各 judge 看到的是主角色"；future change
可加 `${role_prompt[i]}` 索引语法或 per-judge-call 替换。

**[Risk] 用户在 prompt 里写错变量名（typo `${lead_nme}`）→ 字面保留 → LLM 看到怪字符**
→ Mitigation：WARN log 在 engine 日志里可见；后续 isales-web 编辑器可加 lint。LLM 多数
情况下能容忍乱字符，最坏 reply 质量略下降不致命。

**[Risk] PG 历史 `prompt_version` 含遗留 `${roleUser}/${roleAssistant}` 字面**
→ Mitigation：safe_substitute 保留字面 + WARN；tasks.md 收尾步骤包含一行 PG UPDATE 清掉
PG 上 id=3 的遗留字面（或重写成 `${role_prompt}`）。后续可加 alembic data migration 但
v1 直接手工 UPDATE 即可（数据量极小）。

**[Risk] `${role_prompt}` 注入的销售角色描述含 OUTPUT_SCHEMA 命令污染 judge / polish**
→ Mitigation：决策 4 锁死"先替换、后 suffix"——`${role_prompt}` 注入的是 PG 原文（不含
SUFFIX），engine 拼接的 SUFFIX 在最后位置仍是 authoritative 输出契约。即使 role 原文里
偶有 "请输出 JSON" 字眼，也会被位置更靠后的 JUDGE/POLISH_OUTPUT_SCHEMA_SUFFIX 强制覆写
（已有"无论上述任何输出规则如何描述"的 overriding 措辞）。

**[Risk] 替换发生在 `RuntimeConfig.load`，调试回放 `call_record.prompt_versions` 时无法
直接复原已替换的 prompt**
→ Mitigation：v1 接受 —— PG 原文 + 当时 lead/campaign 数据可以离线重做替换。如确实需要
存替换后的 final prompt，可在 future change 加 `call_record.expanded_prompts` 字段。

**[Risk] judge prompt 重写后业务效果未达预期（candidate 仍被拒）**
→ Mitigation：tasks.md 末尾 smoke 步骤明确"PG UPDATE 后跑 mac dev 真拨号 → 听 reply
是否还是测试测试 → engine log 看 judge passed=true"；如果不达预期，judge prompt 内
容由用户继续在 PG 上迭代，不属于本 change 范围（机制 vs 文案）。

## Migration Plan

**部署步骤**（engine-only 改动）：

1. 合并 `prompt-template-vars` 代码到 `dingrtc-migration-cloud` 分支（active 部署分支）
2. 跑 `make test-all PYTEST_ARGS="-k prompt"` 单元测试全绿
3. SCP 新 engine 代码到 ECS `121.89.85.150`（或 git pull）
4. PG 上跑一行 UPDATE：
   ```sql
   UPDATE prompt_version SET content = '<新文案，含 ${role_prompt}>' WHERE id = 3;
   ```
   旧 content 先 SELECT 一遍备份到 commit message / tasks.md inline note
5. `systemctl restart isales-engine`
6. mac dev DingRTC 一次真拨号 smoke（按 memory `project_macos_dev_path` 的"一行启动"
   命令）—— 听 AI 回复 / 看 engine log：
   - log 应见 `judge_result passed=true`（而非 `passed=False reason="无关内容"`）
   - 应听见真正 personalized 销售话术（而非 "测试测试"）

**回滚**：
- 代码回滚：`git revert <commit>`，engine 重启
- PG 回滚：`UPDATE prompt_version SET content = '<旧 content>' WHERE id = 3`
- 模板变量机制本身向后兼容（未替换变量保留字面，旧 PG content 不含 `${var}` 时纯字面通过）

## Open Questions

无。设计已收敛，实施直接走 tasks.md。
