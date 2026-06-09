## ADDED Requirements

### Requirement: main 角色卡单条锁定

campaign 配置页的 AI 角色编辑区中，`kind=main` 的角色卡 SHALL 被特殊化为「单条、必有、锁定」：MUST NOT 提供 enable/disable 开关（main 恒为启用）、MUST NOT 提供删除入口、MUST NOT 提供新增第二个 main 的入口、`name`/`label` 字段对 main SHALL 只读或隐藏（main 不进 `routing_rules`，label 对其冗余）。对 `kind=main`，本约束 SHALL 覆盖 §「三 LLM prompt 编辑（per-campaign）」中对 main/referee/extractor 三角色**同构**（均提供 name + enable 开关 + 增删）的泛化处理——更具体者优先。`kind ∈ {referee, extractor}` 的角色卡行为 MUST NOT 受本约束影响（维持可命名/可禁用/可增删）。

理由：data-model SHALL 保证 `kind=main` 每 campaign 恰好 1 行且 mandatory（引擎流式回复唯一驱动，`_first(RoleKind.MAIN)`）；禁用 / 删除 / 新增第二个 main 都会破坏该不变量或使 pipeline 失去主回复流。

#### Scenario: main 卡无禁用 / 删除 / 新增入口

- **WHEN** 用户打开 campaign 详情页的 AI 角色编辑区
- **THEN** main 角色卡 MUST NOT 渲染 enable/disable 开关、删除按钮、或"新增 main"入口
- **AND** referee / extractor 角色卡 SHALL 继续渲染各自的 enable 开关与增删入口

#### Scenario: main 卡名字字段锁定

- **WHEN** 用户查看或编辑 main 角色卡
- **THEN** `name`/`label` 字段 SHALL 只读或隐藏，MUST NOT 允许用户改写
- **AND** 已落库的 main `role_config.name` 历史值 SHALL 保留（仅前端不可编辑，MUST NOT 触发删除或清空）

#### Scenario: 不可创建第二个 main

- **WHEN** campaign 已存在一个 `kind=main` role_config
- **THEN** UI MUST NOT 提供任何创建第二个 `kind=main` 的路径（无新增按钮、无"复制 main"动作）

### Requirement: persona 推测并发上限（persona_fanout_cap）配置控件

campaign「多流路由」配置区 SHALL 提供 `persona_fanout_cap` 的可视编辑控件（数字步进器或等价控件，取值 clamp 到 [1,3]）。`persona_fanout_cap=1` SHALL 呈现为"关闭多人设推测（仅 main）"语义；`2`/`3` 为开启、定义每轮并行推测路由总数（含 main）的上限。控件值 SHALL 通过 campaign PATCH 持久化（后端 `CampaignUpdate.persona_fanout_cap` 已暴露），MUST NOT 仅存于浏览器 localStorage。

#### Scenario: 调节 cap 并持久化

- **WHEN** 用户在「多流路由」配置区把 `persona_fanout_cap` 从 1 改为 2 并保存
- **THEN** UI SHALL 通过 campaign PATCH 写入 `persona_fanout_cap=2`
- **AND** 重新加载该 campaign 时控件 SHALL 显示持久化后的值

#### Scenario: cap 取值边界

- **WHEN** 用户尝试把 `persona_fanout_cap` 设为 0、负数或 > 3
- **THEN** 控件 SHALL 把取值 clamp 到 [1,3]，MUST NOT 提交越界值

#### Scenario: cap=1 关闭语义提示

- **WHEN** `persona_fanout_cap` 当前为 1
- **THEN** UI SHALL 提示该 campaign 未启用多人设推测（每轮仅 main、无推测 fan-out、无取消计费）

### Requirement: persona 列表卡删除前置校验

campaign「多流路由」配置区的 persona 列表 SHALL 在删除某条 persona 前做客户端预检：若当前已加载的 `routing_rules` 中存在 route action 的目标为该 persona 的 `label`，UI SHALL 提示用户"先在路由规则中移除对该人设的引用"并阻止删除，MUST NOT 直接发起删除请求。若客户端预检漏过、后端返回 422 `routing_rule_unknown_persona`，UI SHALL 将其翻译为同一句可读提示，MUST NOT 向用户暴露裸错误码。

#### Scenario: 删除被路由规则引用的 persona 被拦截

- **WHEN** 用户删除一条 `label` 仍被某 `routing_rules` route action 引用的 persona
- **THEN** UI SHALL 提示"先在路由规则中移除对该人设的引用"并保留该 persona，MUST NOT 删除

#### Scenario: 删除未被引用的 persona 成功

- **WHEN** 用户删除一条无任何 `routing_rules` route action 引用的 persona
- **THEN** UI SHALL 调用 role_config 删除端点移除该 `kind=persona` 行并从列表移除
