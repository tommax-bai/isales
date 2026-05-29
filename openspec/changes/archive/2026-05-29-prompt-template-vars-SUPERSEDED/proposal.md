> **2026-05-29 SUPERSEDED — DO NOT IMPLEMENT.**
>
> 取代者：[`engine-judge-dialog-context`](../archive/2026-05-29-engine-judge-dialog-context/proposal.md)
> （archived 2026-05-29，已实装且 ECS 真拨号实证三 turn judge.passed=true）。
>
> 取代原因：本 change 提议的"PG-stored prompt 加 `${var}` 模板变量替换 + `${role_prompt}`
> 注 judge system prompt 销售场景"路径，意图修 judge 概念错位（2026-05-28 实证全 passed=false
> → 走 default_replies "测试测试" fallback）。本 change 起草后调研 voxen 仓
> （`/Users/bears/codes/voxen-{gateway-,}main`）发现：voxen referee 把对话历史走
> user message 段（`llm_referee.go:75` `ChatHistoryToString`），而非走系统 prompt 模
> 板变量替换（referee system prompt 含 `${roleUser}/${roleAssistant}` 但**没经替换**，
> `r.Config.SystemPrompt` 原文直送）。voxen 在生产 viable 证明：信息修法（chat-history
> in user message）单层就够，不需要概念修法 + 模板变量机制。
>
> 2026-05-29 mac dev DingRTC 真拨号实验补丁（isales-engine 84c5db8 → 332d8b2）严格
> 变量控制——只给 judge 的 user message 加对话历史段，**PG-stored judge prompt 完
> 全不动**——三 turn `judge.passed=true`、polish 输出真销售话术、"测试测试" fallback
> 不再触发（PG `pipeline_trace.call_record_id=51` 实证；详细见 memory
> `project_session_2026_05_29_handoff`）。这反证了 prompt-template-vars 的 5 变量替
> 换机制是过度抽象——解 judge 概念错位用不到，"信息修法"单层胜过"概念修法 + 模板
> 变量"多层。
>
> **本 change 不再推进。** proposal / design / specs / tasks 保留作"为何不走模板变
> 量机制" 的思路记录。实施代码（PromptVars + `_substitute` + 5 变量集 + 7 单元测试
> + 1 集成测试，全绿）保留在 isales-engine 仓 `git stash@{0}` 直到本 change archive
> 时 drop（本 SUPERSEDED 公告同步触发 stash drop）。任何后续 judge / polish 信息缺
> 口问题请走 `engine-judge-dialog-context`（archived 2026-05-29）+ 同一 session
> handoff 记录的 follow-up 路径，**不要**执行本 change 的 tasks。

## Why

PG-stored prompt（`prompt_version.content`，由 isales-web 编辑、`role_config.current_prompt_version_id`
指向）目前是**纯字面字符串**——没有占位符替换机制。这造成两个直接问题：

1. **Judge / Polish prompt 与销售场景脱钩**。2026-05-28 真拨号 session 实证，judge LLM 拿到
   一段无头无尾的销售台词候选，因为 system prompt 把它框成"专业对话应答分析专家"，所以判
   `passed=false reason="...属于无关内容"`，**所有 candidate 全 reject** → orchestrator 走
   default_replies fallback → 用户连续听到"测试测试"。Judge 不知道这是销售场景，也不知道
   销售角色的目标 / 风格 / 合规要求。

2. **历史遗留字面 `${roleUser}` / `${roleAssistant}` 散在 PG 数据里**。当时建表约定但没实
   装替换；现在 LLM 把这些 `${var}` 字面当成怪异 token 解读，进一步污染 judge / polish 的
   理解。

修法的本质是：**让 PG-stored prompt 在 build 阶段获得运行时上下文**（销售角色描述、线索信
息、campaign 名等），从而 judge / polish 可以引用 `${role_prompt}` 显式承接销售场景，
campaign 编辑者也能在话术里复用 `${lead_name}` 等变量。这是 role-prompt spec 已经隐式假设但
没明确要求的能力。

详细背景见 memory `project_session_2026_05_28_handoff` § "judge 概念层错位"。

## What Changes

- **新增 prompt-template-vars 机制**：`prompt_version.content` 字段支持 `${var}` 占位符；
  支持的变量名（v1 最小集）：
  - `${role_prompt}` — campaign 销售角色的 system prompt 原文（取 `roles[0].system_prompt`，
    详见 design § "N-role 处理")
  - `${campaign_name}` — `Campaign.name`
  - `${lead_name}` — `Lead.name`（缺时空串）
  - `${lead_phone}` — `Lead.phone`
  - `${lead_custom_data}` — `Lead.custom_data` 渲染成 `k=v, k=v` 文本

- **替换发生在 `runtime_config.load_runtime_config` 阶段一次性完成**——所有 spec
  (`RoleSpec` / `JudgeSpec` / `PolishSpec`) 的 `.system_prompt` 在送入 `prompt_builder`
  之前已是替换后的字面文本。`build_*_messages` 不感知替换机制，hot path 不受影响。

- **使用 Python 标准库 `string.Template` 语法（`${var}`）**——不引入 jinja2 / mustache /
  自研 mini-DSL；不支持条件 / 循环 / 嵌套（v1 故意保持最小）。

- **未知变量保留字面 + WARN log**——不 raise（PG 历史数据可能含未来变量名）；不退化到
  隐式默认值（避免多层 fallback 反 pattern）。

- **`${role_prompt}` 在 role.system_prompt 内自指**：替换为空串 + WARN log（用户写 role
  prompt 时引用自己没意义，但不致命）。

- **`prompt_builder.py` 的 OUTPUT_SCHEMA_SUFFIX 三常量保持不变**——schema 强约束在替换
  完成后追加，确保 `${role_prompt}` 注入的内容（可能也含 plain-text 输出契约）不会污染
  最终 system prompt 末端的 JSON schema 命令。

- **`prompt_versions` 快照不变**——`call_record.prompt_versions` 仍存原始 `prompt_version_id`，
  指向未替换的 PG content；调试回放从 PG 取原文 + 当时的 lead/campaign 元数据自行复原即可。

- **PG 数据迁移（不在本 change 的代码部分，落在 tasks.md 收尾步骤）**：把当前 `prompt_version.id=3`
  （judge prompt）重写为引用 `${role_prompt}`，让 judge 自动拿到销售场景上下文；删除遗留
  的 `${roleUser}` / `${roleAssistant}` 字面字符串。

## Capabilities

### New Capabilities

无。模板变量是 `role-prompt` spec 的能力扩展，不构成独立 capability。

### Modified Capabilities

- `role-prompt`：新增 Requirement "Prompt 模板变量支持"——平行于已有的"Prompt 三段式组装" /
  "JSON Mode 强制策略" / "Prompt 版本管理" 等 Requirement。明确变量集、替换时机、未知变量
  处理、`${role_prompt}` 自指语义、与 OUTPUT_SCHEMA_SUFFIX 的先后顺序。

## Impact

**受影响代码**（全在 `isales-engine` 仓）：
- `isales-engine/isales_engine/pipeline/prompt_builder.py` — 新增 `PromptVars` dataclass +
  `_substitute(content, vars)` 函数；导出符号
- `isales-engine/isales_engine/runtime_config.py` — `load_runtime_config` 加 PromptVars
  构造 + 对 role / judge / polish 三类 spec.system_prompt 替换
- `isales-engine/tests/test_prompt_builder.py` — 新增 `_substitute` 单元测试覆盖 5 个
  scenario

**不受影响**：
- isales-common（无 schema 变更；`prompt_version.content` 字段类型不变，只是允许内含 `${var}`）
- isales-api / isales-scheduler / isales-worker / isales-web（无契约变更；web 编辑器后续
  *可以*加变量选择 UI，但不在本 change 范围）
- 其他 sibling repo
- cloud-edge gRPC 协议、`CallSession` schema、`call_record.prompt_versions` 快照格式

**APIs / 协议**：均不变。PG schema 不变。

**依赖**：纯 stdlib `string.Template`；无新增 pip 依赖。

**部署**：纯代码 + 一行 PG UPDATE；engine 滚动重启即可生效。无 alembic migration。

**联合验收点**：本 change 闭合后，重跑 mac dev DingRTC 真拨号 smoke，应观察到 judge
`passed=true` 且真 personalized reply 出现（替代 "测试测试" default_replies），即视为
功能性验收通过。E2E 真拨号路径（13301035545）仍归 `joint-mvp-gate-13301035545`。
