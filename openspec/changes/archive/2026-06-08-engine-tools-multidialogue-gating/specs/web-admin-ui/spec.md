## MODIFIED Requirements

### Requirement: campaign 多流路由配置界面

campaign 配置页 SHALL 提供「多流路由」配置区，包含：① 主对话流（main，单条）；② 重组流（restructure，单条，可不配）；③ 裁判列表（N 个 referee，可增删）；④ 路由规则编辑器；⑤ **人设列表（N 个 persona，可增删，opt-in，cap ≤ 3）**；⑥ **工具配置（hangup / transfer，见 § "工具配置界面（ToolsTab）"）**。每个裁判 SHALL 可编辑 label / model / prompt / 输出枚举语义说明。路由规则编辑器 SHALL 让用户按顺序增删规则，每条规则可选「绑定哪个裁判 → 匹配哪些 category → 执行什么 action」；action SHALL 支持 路由到角色(persona) / 工具(挂断·转人工) / 状态转移 / 切重组流，并可选 `then_state` 目标。

#### Scenario: 增删裁判

- **WHEN** 用户在裁判列表点「添加裁判」
- **THEN** 界面 SHALL 新增一行可编辑 referee（label / model / prompt），保存后落 `kind=referee` role_config
- **AND** 删除某裁判时 SHALL 校验无 routing_rules 仍引用其 label，否则提示先改规则

#### Scenario: 路由规则有序编辑

- **WHEN** 用户编辑路由规则
- **THEN** 界面 SHALL 以有序列表呈现规则、支持调整顺序（顺序即优先级），每条规则可选 referee（下拉其 label）+ 匹配 category（多选其枚举）+ action
- **AND** action 编辑器 SHALL 提供四类：① 状态转移（to + goal_type）② 切重组流（source）③ **路由到角色**（route → 下拉 persona label 或内置 closing/recovery/restructure）④ **工具**（tool → 下拉 hangup/transfer alias）；③④ 及①可选 `then_state` 下拉（LISTENING / WRAPPING_UP / ACTIVATING / TRANSFERRING / END）

#### Scenario: 切换 action 目标清空陈旧字段（修 422）

- **WHEN** 用户把某条规则的 action 目标从 `goal_achieved`（带 goal_type）切到其它目标（transfer / route / tool / restructure）
- **THEN** 界面 MUST 清空不再适用的 `goal_type`（及其它陈旧分支字段），使提交载荷只含当前 action 类型的合法字段；MUST NOT 残留 `goal_type` 导致后端 `422` 保存失败（cherry-forward 自 superseded `referee-hangup-action` 的已知 bug 修复）

#### Scenario: 配置重组流

- **WHEN** 用户启用重组流
- **THEN** 界面 SHALL 提供 restructure 的 model + prompt 编辑入口，并提示「输入为被打断残留或上一句要点，prompt 应写重写/包装指令」

#### Scenario: 单裁判向后兼容呈现

- **WHEN** 打开一个仅含单 referee + 默认规则的存量 campaign
- **THEN** 界面 SHALL 正常呈现该单裁判与等价默认规则，用户 MAY 在此基础上加裁判/规则，存量配置 MUST NOT 被破坏

## ADDED Requirements

### Requirement: 工具配置界面（ToolsTab）

campaign 配置页 SHALL 提供工具配置入口（ToolsTab），让用户定义 `hangup` / `transfer` 工具及其 alias，供路由规则的 tool 动作引用。工具配置 SHALL 映射到 `campaign.tools` JSONB（schema 见 data-model spec）。

#### Scenario: 配置挂断工具

- **WHEN** 用户在 ToolsTab 添加一个 `hangup` 工具
- **THEN** 界面 SHALL 提供可选 `closing_phrase`（挂断前单句话术）+ `interrupt` 选项，保存后落 `campaign.tools[<alias>] = {type: hangup, ...}`

#### Scenario: 配置转人工工具

- **WHEN** 用户在 ToolsTab 添加一个 `transfer` 工具
- **THEN** 界面 SHALL 仅需 alias（衔接话术复用既有 `campaign.transfer_phrases` 单一来源，ToolsTab MUST NOT 提供第二套话术输入），保存后落 `campaign.tools[<alias>] = {type: transfer}`

#### Scenario: 工具 alias 唯一性

- **WHEN** 用户添加重复 alias 的工具
- **THEN** 界面 SHALL 阻止保存并提示 alias 重复（对应后端 `422 tool_alias_duplicate`）

### Requirement: persona 角色配置（role kind）

角色配置界面 SHALL 支持 `kind=persona` 角色（label 必填），与 main / referee / restructure / extractor 并列。persona 用于 eager 多人设推测对话（见 ai-pipeline spec）。

#### Scenario: 添加 persona 角色需填 label

- **WHEN** 用户添加一个 persona 角色
- **THEN** 界面 MUST 要求非空 label（同 campaign 内唯一），保存后落 `kind=persona` role_config；删除被路由规则引用的 persona 时 SHALL 提示先改规则（对应后端 delete-guard）

#### Scenario: persona 数量提示 cap

- **WHEN** 用户启用的对话路由总数（main + persona）超过 `persona_fanout_cap`（clamp [1,3]）
- **THEN** 界面 SHALL 提示推测并发上限（含 main 至多 3 条）并阻止超额启用（vendor 对取消的 token 计费）
