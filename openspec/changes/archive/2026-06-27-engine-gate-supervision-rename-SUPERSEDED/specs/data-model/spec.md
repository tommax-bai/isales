<!-- data-model delta: prose-only 门控监管 rename + referee_fail_open_route 永远 release/不 fail-closed 语义标注；保留所有列名/枚举/JSON key 字面量 -->

## MODIFIED Requirements

### Requirement: pipeline_trace 多 referee 与 restructure 字段

`pipeline_trace` SHALL 把单 referee（门控监管）的 `referee_decision/referee_goal_type/referee_confidence/referee_duration_ms` 字段，改为承载 N 个门控监管结果的结构（JSONB 数组，每元素 `{label, category, confidence, duration_ms}`）。SHALL 新增 `matched_rule`（命中的规则快照或索引，可空）、`restructure_active`（bool）、`restructure_trigger`（`last_reply|interrupt_remaining|low_confidence|null`）、`restructure_source_text`（本轮 InterruptText，可空）。

#### Scenario: 多 referee 结果写入

- **WHEN** 一轮 PROCESSING 跑了 3 个门控监管
- **THEN** pipeline_trace 该轮记录的 `referee_results` JSONB 数组 SHALL 含 3 个元素，各带 label/category/confidence/duration_ms

#### Scenario: restructure 轮的 trace

- **WHEN** 本轮命中 restructure action
- **THEN** pipeline_trace SHALL 置 `restructure_active=true`、记 `restructure_trigger` 与 `matched_rule`；门控监管主回复字段按 restructure 语义留空或标记

### Requirement: RoleKind.PERSONA 与 persona 角色配置

`isales_common.enums.RoleKind` SHALL 新增成员 `PERSONA`，`PromptScopeType` SHALL 新增对应 `PERSONA`。`kind=persona` 的 `role_config` 表示一个**可推测并行**的对话人设，其 `label` MUST 非空且在同一 campaign 内唯一（与门控监管 label 命名空间隔离，互不冲突）。persona 复用 main 对话的 model / prompt 结构，参与 eager 多人设门控（见 ai-pipeline spec）。

#### Scenario: persona role_config 落库

- **WHEN** 管理员为 campaign 添加一个 `kind=persona` 角色并填 label
- **THEN** 系统 MUST 以 `RoleKind.PERSONA` 持久化该 role_config，label 非空唯一；MUST NOT 允许空 label 或与同 campaign 内既有 persona label 重复

#### Scenario: persona label 与门控监管 label 命名空间隔离

- **WHEN** 同一 campaign 同时存在 `kind=referee`（门控监管）与 `kind=persona` 且 label 文本相同
- **THEN** 系统 MUST 视为两个独立标识（按 kind + label 寻址），MUST NOT 因 label 文本相同而冲突或互相覆盖

### Requirement: HangupCause.REFEREE_HANGUP 枚举值

`isales_common.enums.HangupCause` SHALL 新增**应用层**值 `REFEREE_HANGUP`，表示「AI 依门控监管裁决主动挂断」的终态。该值 MUST 登记进 `HangupCause` 单一权威枚举（见 call-state-machine § "hangup_cause 单一来源"），下游 `CallEnded` 消息按枚举校验消费方（worker）MUST 先于 engine 部署该枚举（部署序 common → worker → engine）。

#### Scenario: REFEREE_HANGUP 登记进权威枚举

- **WHEN** engine / worker / retry-followup 记录或匹配该挂断原因
- **THEN** 字符串值 MUST 为 `HangupCause.REFEREE_HANGUP` 成员；MUST NOT 在任何映射表引入未登记的平行值

#### Scenario: CallEnded 枚举校验依赖部署序

- **WHEN** engine 发出 `CallEnded(hangup_cause=referee_hangup)`
- **THEN** 消费方 worker MUST 已持有 `REFEREE_HANGUP` 枚举（pin `isales-common>=0.8`）才能通过校验；若 worker 早于 common/engine 升级 MUST NOT 让该 CallEnded 进 DLQ

### Requirement: campaign 门控与多人设配置列

`campaign` SHALL 新增三列控制门控与推测并行：

- `persona_fanout_cap` (int, 默认 1, clamp ∈ [1,3])：**每轮并行推测的对话路由总数（含 main）**；`1` = 仅 main、无推测（opt-in 默认关）；`3` = main + 至多 2 个 persona
- `referee_timeout_ms` (int, 默认 ~600)：开口前门控监管（与 main 并行执行的门控 LLM）超时
- `referee_fail_open_route` (str, 默认 `"main"`)：门控 timeout/fail 时 release 的目标路由——**永远 release，不 fail-closed**（超时/失败 SHALL fail-open 放行该路由，绝不 hold）

#### Scenario: 门控配置被引擎消费

- **WHEN** engine 起一轮门控
- **THEN** engine MUST 用 `campaign.referee_timeout_ms` 作为门控监管超时、`referee_fail_open_route` 作为 fail-open（永远 release，不 fail-closed）的目标路由、`persona_fanout_cap`（clamp [1,3]）作为本轮并行推测对话路由总数（含 main）的上限

#### Scenario: 列默认值向后兼容

- **WHEN** 存量 campaign 无这三列值
- **THEN** 系统 MUST 用默认（`persona_fanout_cap=1` 仅 main 无推测 / `referee_timeout_ms≈600` / `referee_fail_open_route="main"`）；行为等价于仅 main 对话 + fail-open-to-main
