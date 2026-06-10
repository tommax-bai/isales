## MODIFIED Requirements

### Requirement: persona 推测并发上限（persona_fanout_cap）配置控件

campaign 的 persona 配置卡 SHALL 在卡头提供一个**功能开关**作为 `persona_fanout_cap` 的主控件——该开关是**真实启用/关闭多人设推测**的功能开关，而非仅控制页面展开/收起的纯前端折叠。开关切到「关」SHALL 写 `persona_fanout_cap=1`（仅 main、无推测 fan-out、无取消计费）；切到「开」SHALL 写 `persona_fanout_cap≥2`（从 1 切开时默认置 2）。卡体的展开/收起 SHALL 跟随该开关（开=展开、关=收起）。

开关为「开」时，persona 卡卡体 SHALL 提供「人设并发上限」数字控件（取值 clamp 到 [2,3]，定义每轮并行推测路由总数（含 main）的上限）；该并发上限数字控件 SHALL NOT 再出现在「门控路由 / 多流路由」配置区（已迁入 persona 卡）。控件值 SHALL 通过 campaign PATCH 持久化（后端 `CampaignUpdate.persona_fanout_cap` 已暴露），MUST NOT 仅存于浏览器 localStorage，MUST NOT 仅作纯前端展开态而不落库。

实现 SHALL 复用 `persona_fanout_cap` 作为开/关的唯一承载（`1`=关、`2/3`=开），MUST NOT 为此另引入独立的 `persona_enabled` 布尔字段（避免 `cap=1` 与 `enabled=false` 两处可表达"关"的冗余状态）。

#### Scenario: 开关关闭即关闭功能并落库 cap=1

- **WHEN** 用户在 persona 卡把卡头功能开关切到「关」并保存
- **THEN** UI SHALL 通过 campaign PATCH 写入 `persona_fanout_cap=1`，卡体 SHALL 收起
- **AND** 引擎据此每轮仅起 main、无推测 fan-out、无取消计费

#### Scenario: 开关开启即启用功能并落库 cap≥2

- **WHEN** 用户把 persona 卡卡头功能开关从「关」切到「开」
- **THEN** UI SHALL 把 `persona_fanout_cap` 置为 2（若当前 <2，否则保留现值 2/3），卡体 SHALL 展开露出「人设并发上限」(2/3) 控件与人设列表
- **AND** 保存后 SHALL 通过 campaign PATCH 持久化该值

#### Scenario: 卡内并发上限取值边界

- **WHEN** 功能开关为「开」，用户调「人设并发上限」数字控件
- **THEN** 控件取值 SHALL clamp 到 [2,3]，MUST NOT 提交越界值
- **AND** 「门控路由 / 多流路由」配置区 MUST NOT 再渲染该并发上限控件

#### Scenario: 重新加载回显开关与上限

- **WHEN** 用户重新加载 campaign
- **THEN** `persona_fanout_cap≥2` 的 campaign：persona 卡功能开关 SHALL 回显为「开」、卡体展开、并发上限控件 SHALL 显示持久化后的值
- **AND** `persona_fanout_cap=1` 的 campaign：功能开关 SHALL 回显为「关」、卡体收起
