<!-- 叠在 pipeline-stream-and-referee 的 main/referee/extractor 三段配置之上：
     把 referee 单行配置改为「多流路由」界面 — 主对话流 + 重组流 + N 个裁判 + 路由规则编辑。 -->

## ADDED Requirements

### Requirement: campaign 多流路由配置界面

campaign 配置页 SHALL 提供「多流路由」配置区，包含：① 主对话流（main，单条）；② 重组流（restructure，单条，可不配）；③ 裁判列表（N 个 referee，可增删）；④ 路由规则编辑器。每个裁判 SHALL 可编辑 label / model / prompt / 输出枚举语义说明。路由规则编辑器 SHALL 让用户按顺序增删规则，每条规则可选「绑定哪个裁判 → 匹配哪些 category → 执行什么 action」。

#### Scenario: 增删裁判

- **WHEN** 用户在裁判列表点「添加裁判」
- **THEN** 界面 SHALL 新增一行可编辑 referee（label / model / prompt），保存后落 `kind=referee` role_config
- **AND** 删除某裁判时 SHALL 校验无 routing_rules 仍引用其 label，否则提示先改规则

#### Scenario: 路由规则有序编辑

- **WHEN** 用户编辑路由规则
- **THEN** 界面 SHALL 以有序列表呈现规则、支持调整顺序（顺序即优先级），每条规则可选 referee（下拉其 label）+ 匹配 category（多选其枚举）+ action（状态转移 to+goal_type / 切重组流 source）

#### Scenario: 配置重组流

- **WHEN** 用户启用重组流
- **THEN** 界面 SHALL 提供 restructure 的 model + prompt 编辑入口，并提示「输入为被打断残留或上一句要点，prompt 应写重写/包装指令」

#### Scenario: 单裁判向后兼容呈现

- **WHEN** 打开一个仅含单 referee + 默认规则的存量 campaign
- **THEN** 界面 SHALL 正常呈现该单裁判与等价默认规则，用户 MAY 在此基础上加裁判/规则，存量配置 MUST NOT 被破坏
