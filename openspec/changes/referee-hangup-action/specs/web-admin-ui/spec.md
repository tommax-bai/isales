## MODIFIED Requirements

### Requirement: campaign 多流路由配置界面

campaign 配置页 SHALL 提供「多流路由」配置区，包含：① 主对话流（main，单条）；② 重组流（restructure，单条，可不配）；③ 裁判列表（N 个 referee，可增删）；④ 路由规则编辑器。每个裁判 SHALL 可编辑 label / model / prompt / 输出枚举语义说明。路由规则编辑器 SHALL 让用户按顺序增删规则，每条规则可选「绑定哪个裁判 → 匹配哪些 category → 执行什么 action」。action 编辑器 SHALL 支持 `transition`（状态转移）/ `restructure`（切重组流）/ `hangup`（主动挂断）三类。

#### Scenario: 增删裁判

- **WHEN** 用户在裁判列表点「添加裁判」
- **THEN** 界面 SHALL 新增一行可编辑 referee（label / model / prompt），保存后落 `kind=referee` role_config
- **AND** 删除某裁判时 SHALL 校验无 routing_rules 仍引用其 label，否则提示先改规则

#### Scenario: 路由规则有序编辑

- **WHEN** 用户编辑路由规则
- **THEN** 界面 SHALL 以有序列表呈现规则、支持调整顺序（顺序即优先级），每条规则可选 referee（下拉其 label）+ 匹配 category（多选其枚举）+ action（状态转移 to+goal_type / 切重组流 source / 主动挂断 closing_phrase）

#### Scenario: 配置挂断动作

- **WHEN** 用户把某条规则的 action 类型选为「挂断」
- **THEN** 界面 SHALL 提供一个可选的「挂断前话术」输入（留空=立即挂断；填写=先播该句再挂）
- **AND** 界面 SHALL 提示「挂断与『客户拒绝』的区别：拒绝=继续兜底挽留，挂断=当场结束通话」
- **AND** hangup action MUST NOT 显示 `to` / `goal_type` / `source` 等无关字段

#### Scenario: 切换 action 目标时清理无关字段

- **WHEN** 用户把某条 transition 规则的目标从 `goal_achieved` 改为 `transfer` 或 `customer_decline`
- **THEN** 界面 MUST 清空该规则的 `goal_type`（避免提交 `goal_type` 非空但 `to != goal_achieved` 被后端 422 拒绝）
- **AND** 用户在 transition / restructure / hangup 三类 action 间切换时，界面 MUST 重置 action 为该类的合法默认形状（不残留上一类的字段）

#### Scenario: 配置重组流

- **WHEN** 用户启用重组流
- **THEN** 界面 SHALL 提供 restructure 的 model + prompt 编辑入口，并提示「输入为被打断残留或上一句要点，prompt 应写重写/包装指令」

#### Scenario: 单裁判向后兼容呈现

- **WHEN** 打开一个仅含单 referee + 默认规则的存量 campaign
- **THEN** 界面 SHALL 正常呈现该单裁判与等价默认规则，用户 MAY 在此基础上加裁判/规则，存量配置 MUST NOT 被破坏
