## Why

iSales 三层 AI 管线的 judge LLM 之前调用合约是 `build_judge_messages(judge, candidate_reply)`
——user message 只含**孤立**的 candidate 单句，**不带任何对话上下文**。配合 PG-stored judge
system prompt（"专业对话应答分析专家"框定 + 隐含承接性判断目标），导致 2026-05-28 真拨号
实证 judge 全部 `passed=False reason="...无承接关系，属于无关内容"`，pipeline 走 default_replies
fallback "测试测试"，无法进行真实对话（详见 memory `project_session_2026_05_28_handoff` §
"judge 概念层错位"）。

真因是**信息缺口**：judge 需要做承接性判断但 user message 段不带对话历史。voxen
referee 早就走同样路径——`/Users/bears/codes/voxen-main/internal/voice/processor/assistant/chat/router/llm_referee.go:75`
用 `ChatHistoryToString(history, ...)` 把对话历史拼成 user message 段送给 LLM；
voxen 在生产 viable，证明这条路通。

2026-05-29 实验补丁 `isales-engine@84c5db8` 已 SCP 部署 ECS（`121.89.85.150`，规则见
`feedback_ecs_deploy_scp`），mac dev 真拨号 PG `pipeline_trace.call_record_id=51` 实证
**三 turn 全部 `passed=true`**，reason 反复出现"承接对话历史"。**PG-stored judge prompt
完全不变**——唯一变化是 user message 段加了对话历史。

本 change 是 post-hoc 规范化——把已实装、已实证的 `84c5db8` 合并 commit 的"chat-history
into judge"那一半正式纳入 spec，让 `role-prompt` capability 文档跟上代码现状。改动**无
实施风险**，主要是 spec 文档同步 + 单元测试补全 + 实证记录归档。

## What Changes

- **`build_judge_messages` 签名变更**：`(judge: JudgeSpec, candidate_reply: str)` →
  `(judge: JudgeSpec, candidate_reply: str, session: CallSession)`。user message 重组为
  两段：
  - `### 对话历史` 段：按 `用户：xxx / AI：xxx` 格式拼，跟 role 的对话渲染同风格；
    空历史用显式占位符 `（尚无对话历史，这是首轮回复）`，**不**留空
  - `### 销售 AI 准备发给客户的候选回复` 段：candidate 文本
  - 末尾保留 `按上述系统提示的 JSON schema 输出。` guard（OpenAI-compat JSON mode
    需要 messages 含字面 `json`）

- **新增辅助函数 `_render_dialog_history_for_judge(session: CallSession) -> str`**：
  跟 `_render_dialog` 同 `用户：/AI：` 中文角色标签 + 全角冒号风格，但**不带**尾部
  `AI:` 提示行（judge 不是要说话的角色），空历史返回上述占位字符串。**故意**与
  `_render_dialog` 独立而不合并——二者在尾行 / 空处理两个细节上不同，强行抽象会
  耦合无关参数。

- **`_run_judges_parallel` 加 `session: CallSession` 参数**透传给
  `build_judge_messages`。`run_pipeline` 调用方同步加传 `session=session`。

- **spec delta（role-prompt capability）**：ADDED Requirement "Judge 拿到对话上下文"，
  约束 engine 这一侧 user message 拼装规则；**MUST NOT** 约束 PG-stored judge prompt
  文案（业务侧自定义）。与现有 `JUDGE_OUTPUT_SCHEMA_SUFFIX` 机制正交——SUFFIX 仍
  追加到 system prompt 末尾。

- **不动**：PG `prompt_version` 行（含 id=3 judge 文案）、`JUDGE_OUTPUT_SCHEMA_SUFFIX`
  三常量、`generate_greeting` / `build_role_messages` / `build_polish_messages` /
  `build_greeting_messages` 拼装路径、`run_pipeline` 状态机、`call_record.prompt_versions`
  快照格式。

## Capabilities

### New Capabilities

无。本 change 是 `role-prompt` capability 的能力扩展。

### Modified Capabilities

- `role-prompt`：新增 Requirement "Judge 拿到对话上下文"——平行于已有的 "Prompt 三段式组装"
  / "JSON Mode 强制策略" / "Prompt 版本管理" 等 Requirement。明确 engine 在调用 judge LLM 时
  user message 段的拼装规则、空历史处理、与 system prompt OUTPUT_SCHEMA_SUFFIX 的关系，以及
  spec 不约束 PG-stored judge prompt 文案的边界。

## Impact

**受影响代码**（全在 `isales-engine` 仓，已实装 commit `84c5db8`）：
- `isales-engine/isales_engine/pipeline/prompt_builder.py` — `build_judge_messages` 签名 + user
  message 重组 + 新增 `_render_dialog_history_for_judge`
- `isales-engine/isales_engine/pipeline/orchestrator.py` — `_run_judges_parallel` 加 session
  参数透传 + `run_pipeline` 调用方
- `isales-engine/tests/test_pipeline.py` — **本 change 补**：新增 `build_judge_messages` 含
  session 的单元测试 case（空历史 / N 轮历史 / 用户最新一句承接）。当前 grep 显示无现存测试
  覆盖该函数

**不受影响**：
- isales-common（无 schema 变更；CallSession / DialogTurn 类型不变）
- isales-api / isales-scheduler / isales-worker / isales-web（无契约变更）
- cloud-edge gRPC 协议、`CallSession` schema、`call_record.prompt_versions` 快照格式
- PG schema、`prompt_version` 表数据

**APIs / 协议**：均不变。`build_judge_messages` 是模块内函数，签名变更只影响
isales-engine 仓内的调用方（orchestrator 一处）。

**依赖**：无新增 pip 依赖。

**部署**：代码已 SCP 部署 ECS 跑稳（`84c5db8`），本 change archive 时仅需提交 spec 文档
+ 单元测试到 origin。无 ECS 端额外动作。无 alembic migration。

**Token 成本影响**：judge prompt_tokens 从 ~100 涨到 ~2000+（注入对话历史）。每 turn N
candidates × M judges 累积，但 v1 N=1 M=1 是常态。接受 v1 代价——比 prompt-template-vars
拟用的 `${role_prompt}` 注入（销售角色 prompt 全文 ~2000+）还便宜些（对话历史段通常比
role prompt 全文短）。详见 design.md § "token 成本"。

**联合验收已通过**：mac dev DingRTC 真拨号 PG `pipeline_trace.call_record_id=51` 三 turn
全 `passed=true`、polish_output 真销售话术、default_replies "测试测试" fallback 不再触发。
实证完整记录在 memory `project_session_2026_05_29_handoff` § "实验结果"。
