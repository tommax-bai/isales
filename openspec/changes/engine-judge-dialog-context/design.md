## Context

iSales 三层 AI 管线（role / judge / polish）中，judge LLM 的职责是审查 role 输出的
candidate 是否适合发给客户。两层关键信息缺口在 2026-05-28 真拨号 session 暴露（见
`project_session_2026_05_28_handoff` § "judge 概念层错位"）：

1. **判断目标错位**：PG-stored judge prompt 当前是"专业对话应答分析专家"框定，目标"判
   断输入回复是否有意义"——但 orchestrator 实际把销售 AI 准备发的话作为 candidate 喂
   给它做销售质量评判，是个跟 prompt 表述不完全一致的任务。
2. **信息不足**：`build_judge_messages(judge, candidate_reply)` 当时只把 candidate 单
   句拼进 user message——judge 想做承接性判断但**没有对话历史**，自然 reject 所有
   candidate。

2026-05-28 session 选了"信息修法"+"概念修法"叠加路径——起 `prompt-template-vars` change
用 `${role_prompt}` 把销售角色 prompt 注入 judge system prompt（销售场景上下文 + 概念
重框定）。该 change 已写完 4 个 artifact + 7 单测全绿 + 代码实装（停在 `git stash@{0}`
"prompt-template-vars WIP"）。

2026-05-29 调研 voxen 仓发现**voxen referee 走的是另一条路**——`llm_referee.go:75` 把
`ChatHistoryToString(history, ...)` 拼成 user message 段送给 LLM，referee 的 system
prompt 含 `${roleUser}/${roleAssistant}` 但**没经替换**（`r.Config.SystemPrompt` 原文
直送给 LLM）。voxen 在生产 viable，证明"对话历史 → user message 段"这条最小修法
足以解 judge 信息缺口。

实验验证（2026-05-29 真拨号 PG `pipeline_trace.call_record_id=51`）：**PG-stored judge
prompt 完全不动**，只给 user message 加对话历史段，三 turn 全 `passed=true`，polish
输出真销售话术。**信息修法单层就够，概念修法不必要**。

本 change 把信息修法（chat-history into user message）spec 化，不做概念修法。

## Goals / Non-Goals

**Goals:**

- 把 2026-05-29 实验补丁 `84c5db8` 在 isales-engine 仓的 chat-history 那部分正式落到
  `role-prompt` capability spec
- 明确 engine 在调用 judge LLM 时 user message 段的拼装规则：两段 markdown 风格
  section + 显式空历史占位
- 划定本 change 边界——**不**约束 PG-stored judge prompt 文案、**不**约束 polish 端、
  **不**做模板变量机制
- 补 unit test 覆盖（当前 `tests/test_pipeline.py` 无 `build_judge_messages` 测试）

**Non-Goals:**

- **不**做 prompt 模板变量替换（`prompt-template-vars` 那条路被本 change 反证不必要——
  待 step 1 archive / 标 SUPERSEDED）
- **不**改 PG `prompt_version.id=3`（judge 文案）——实证表明文案不动 + 信息可用就足以
  让 judge 工作；业务侧可继续按需迭代文案，不在本 change 范围
- **不**改 `JUDGE_OUTPUT_SCHEMA_SUFFIX` 三常量（system prompt 末尾的 JSON schema 强
  约束机制保留）
- **不**给 polish 注入对话历史——polish 当前只看 N candidates 选优，跟"承接判断"任
  务不同；后续视情况另起 change
- **不**改 fixed greeting hack（`runtime_config._FIXED_GREETINGS={1:"..."}` 跟本 change
  同 commit `84c5db8` 但属另一件事，走 `campaign-fixed-greeting` change 转正）
- **不**抽象 `_render_dialog` / `_render_dialog_history_for_judge` 为同一函数——
  二者在尾行处理 / 空处理两个细节不同，强行抽象会耦合无关参数

## Decisions

### 决策 1：信息修法路径 = user message 段拼对话历史（不走模板变量）

**选择**：user message 段加 `### 对话历史` + `### 销售 AI 准备发给客户的候选回复` 两
段 markdown 风格 section。

**备选**：

- A. 模板变量机制（prompt-template-vars 原方向）：让 PG-stored judge prompt 用
  `${role_prompt}` / `${dialog_history}` 等占位符，runtime 替换。
- B. 改 PG-stored judge prompt 文案（概念修法）：把"专业对话应答分析专家"改成"销
  售话术质量评判员" + 文案里写"结合下方对话历史判断 candidate"。
- C. 本方案（信息修法 + 不动文案 + 不走模板）。

**为何选 C 不选 A**：

- voxen referee 实证 `llm_referee.go:71` system prompt **不替换变量**，直接原文送 LLM；
  line 75 的 chat_history 走 user message 段。voxen 业务跑稳证明这条路 viable
- voxen 仓里**根本没实装** `${roleUser}/${roleAssistant}` 替换（system prompt 占位符
  字面留给 LLM）；模板变量机制是过度抽象
- 跟 iSales `build_role_messages` 模式一致——role 的对话历史也是走 user message 段
  `_render_dialog`，不走模板变量。本 change 让 judge 跟 role 走同一条路，认知负担
  最小
- 2026-05-29 实验实证：PG 文案不动 + user message 加历史，三 turn 全 passed=true。
  模板变量机制原本要解的 "judge 概念错位" 问题已被信息修法间接解掉——judge 看到
  对话历史后能识别销售承接性，"对话应答分析专家"这个框定 LLM 自己消化掉了

**为何选 C 不选 B**：

- 业务侧自定义 prompt 是 `role-prompt` capability 已有原则（`Requirement: Prompt 由
  Campaign 完全自定义`）。Engine 改业务文案是违反这条 spec
- 实证表明文案不改也能工作，没必要动
- 即使将来要改文案，是 PG UPDATE，不是代码 change——本 change 范围跟 prompt 文案
  解耦

### 决策 2：空对话历史用显式占位字符串，不留空段

**选择**：`session.dialog_history` 为空时（greeting 后 first turn 评判），
`_render_dialog_history_for_judge` 返回字面字符串 `（尚无对话历史，这是首轮回复）`。

**备选**：

- A. 返回空串——user message 段会渲染成 `### 对话历史\n\n\n### 销售 AI 准备...`
- B. 完全省略对话历史段——user message 只含候选回复段
- C. 本方案（显式占位字符串）

**为何选 C**：

- 让 user message 结构一致——judge 每次看到的 user message 段结构相同（两段 section），
  减少 LLM 困惑面
- 显式告知 LLM "这是 greeting 后首轮"，避免 LLM 把空历史段误读成 prompt 残缺 / 信号
  缺失
- 跟 `build_greeting_messages` 现有的 "无对话历史" 实证一致 —— greeting 直接用 role
  prompt 没历史也 work，judge 类似情况显式标注比留空安全

### 决策 3：新增 `_render_dialog_history_for_judge` 跟 `_render_dialog` 独立，不合并抽象

**选择**：写一个新函数，跟 `_render_dialog` 风格相似但细节独立。

**备选**：

- A. 抽象成 `_render_dialog(session, *, trailing_ai_prompt=False, empty_placeholder=None)`
  共用一个函数加参数控制
- B. 直接复用 `_render_dialog`——judge 也带 `AI:` 尾行
- C. 本方案（两个独立函数）

**为何选 C**：

- `_render_dialog` 在尾行追加 `AI:`（提示 role "接下来该你说话"），judge 不是说话角色，
  不该带这个尾行。语义不同
- 空历史处理不同：role 用 `_render_dialog` 时通常已经有 greeting 进 dialog_history，
  不会真空；judge 在 turn=1 时会真空，需要占位
- A 方案的参数化会让 `_render_dialog` 签名变复杂，调用方要传无关参数，破坏 role 端
  代码简洁
- 两个函数各自 6-10 行，重复成本很低；强行抽象代价 > 收益（feedback
  `feedback_avoid_multilayer_fallback` 反 pattern 的同源思路：少抽象一层更清）

### 决策 4：user message 用 markdown `###` section 标题而非纯文本

**选择**：用 `### 对话历史` / `### 销售 AI 准备发给客户的候选回复` 两个 markdown
heading 分段。

**备选**：

- A. 纯文本 `【对话历史】\n...\n\n【候选回复】\n...`（跟 role 的 `_render_dialog` 用
  `【对话】` 风格一致）
- B. 本方案（markdown `### section`）

**为何选 B**：

- voxen referee 用 `###` 风格分段（`ChatHistoryToString` 实现里用 `\n###\n` 包裹），
  跟 voxen 实证保持一致风格
- LLM（dashscope qwen 系列）对 markdown 标题敏感度比中文 `【】` 高，段落分隔感更
  清晰
- 实证 `pipeline_trace.call_record_id=51` 三 turn judge reason 反复出现"对话历史"、
  "承接"字眼，说明 LLM 在 user message 里把对话历史段当作独立信息源处理——markdown
  分段 work

**Trade-off**：跟 role 端 `【对话】` 风格不严格一致。接受——role 和 judge 拼装函数本
就不需要严格风格统一（system prompt 和 lead info 段就已经各用各的格式）。

### 决策 5：本 change 仅做 judge，不做 polish

**选择**：polish 的 `build_polish_messages` 不动，仍只看 N candidates 选优。

**理由**：

- polish 任务是 "从 N 个候选里选 / 润色"，不需要做承接性判断——上游 N candidates
  本身已经是承接对话的产物
- 实证 `pipeline_trace.call_record_id=51` 三 turn polish_output 都是高质量真销售话
  术，说明 polish 当前信息够用
- 加 polish 历史会增加 token 成本（同 judge 一样涨 ~2000 tokens / call）但无明显收益
- 留作 future change（如果将来发现 polish 在长对话里走偏，再加历史）

## Risks / Trade-offs

**[Risk] Judge token 成本上升（~100 → ~2000+ tokens/call）**
→ Mitigation：v1 N=1 M=1 是常态，累积成本可控。比 prompt-template-vars 原方案
（`${role_prompt}` 注 system prompt = role 全文 ~2000+ tokens）还便宜些（对话历史
段通常比 role prompt 全文短）。监控 pipeline_trace 的 judge duration_ms，长对话
（>30 轮）有需要时再做摘要 / 截断（独立 future change）。

**[Risk] Judge 拿到对话历史后可能跟 role 站同一边（信息对称问题）**
→ Mitigation：实证 `pipeline_trace.call_record_id=51` 三 turn judge passed=true，
但 reason 显示 LLM 是基于"承接性"做正向判断而非简单同步 role。Judge 仍是不同
LLM 实例，PG prompt 框定的视角不同（"对话应答分析"角度判承接性 vs role 的"销售
推进"角度），实质上仍是第二意见。如果未来发现 judge 简单 rubber-stamp role，可
独立 change 调整 judge prompt 文案让它视角更对立。

**[Risk] 空历史占位字符串"（尚无对话历史，这是首轮回复）"在 LLM 看来可能不自然**
→ Mitigation：实证场景里 turn=1（call_record_id=51 turn=1 user_input="哎，你好。"）
其实**不是**严格空历史——dialog_history 此时已经有 greeting 那条（`session.append_event("greeting")`
进 dialog_history，详见 `call_session.DIALOG_EVENT_TYPES`）。所以实证里没真触发空
分支。但 spec 仍要明确空时的行为，避免将来 greeting 路径变更后行为未定。

**[Risk] `_render_dialog_history_for_judge` 跟 `_render_dialog` 代码重复（轻微）**
→ Mitigation：决策 3 已接受。两个函数各 6-10 行，差异恰好是"尾行 `AI:`" + "空处理"
两个细节——这两个细节正是 role 和 judge 的语义差。重复成本远小于强行抽象的耦合
成本。

**[Risk] PG-stored judge prompt 文案后续被业务方误改成不带"承接判断"的内容**
→ Mitigation：spec 显式声明"本 Requirement 仅约束 engine 这一侧拼装规则，PG-stored
judge prompt 文案由 Campaign 完全自定义"。业务方有权改文案——如果改坏了导致 judge
表现下降，是业务侧 PG UPDATE 调整范围，不在 engine spec 范围。前置依赖：业务方理
解 judge 是"承接性评判员"语义（这层认知通过 isales-web 编辑器 UI 或者文档传递）。

## Migration Plan

**部署**：本 change 的代码改动**已部署 ECS**（commit `84c5db8`，SCP 部署 + systemctl
restart isales-engine + journalctl 验证启动正常 + 真拨号 PG 实证）。本 change archive
时**无额外部署动作**——只是把 spec 文档和单元测试同步到 origin。

**回滚路径**：

- 代码回滚：`git revert 84c5db8` 在 isales-engine 仓本地（恢复 `build_judge_messages`
  签名 + orchestrator 调用 + 删 `_render_dialog_history_for_judge`）；SCP 三文件回
  ECS；systemctl restart isales-engine。代价：judge 重新回到 2026-05-28 "全 passed=false
  + 测试测试 fallback" 状态。
- spec 回滚：删 `openspec/specs/role-prompt/spec.md` 里的 "Judge 拿到对话上下文"
  Requirement。

**与其他 active change 的关系**：

- `prompt-template-vars`（stash 里 + meta-repo 上 untracked 文档）：本 change 反证
  其不必要 → 走 step 1（archive / 标 SUPERSEDED）。`prompt-template-vars` 的 stash
  代码可 drop。
- `campaign-fixed-greeting`（待起，step 3）：跟本 change 独立。`84c5db8` 同 commit
  改了 `runtime_config._FIXED_GREETINGS` 字典 hack——那部分**不**纳入本 change，待
  `campaign-fixed-greeting` 走跨 4 仓 feature。

## Open Questions

无。所有设计点已收敛。
