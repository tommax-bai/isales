## MODIFIED Requirements

### Requirement: 客户面 view 清单

`isales-web` SHALL 实现以下客户视角 view（系统单一角色，所有 view 同属「用户」工作台，无运营/客户分区）：

| 入口 | 路由 | view 文件 |
|---|---|---|
| 场景管理 | `/campaigns` | `views/Campaigns/CampaignWorkspace.vue` |
| 场景详情 | `/campaigns/:id` | `views/Campaigns/CampaignDetail.vue` |
| 线索管理 | `/leads` | `views/Leads/LeadList.vue` |
| 外呼记录 | `/calls` | `views/Calls/CallList.vue` + `views/Calls/CallDetail.vue` |
| 数据看板 | `/dashboard` | `views/DashboardView.vue`（由运营区升为客户顶级入口） |
| 模型厂商 | `/config/model-providers` | `views/Config/ModelProviderConfig.vue` |

预约管理 view 已随 change `admin-prune-vestigial-features` 删除（预约功能整体下线）。低频但后端已实装的 view（通话监控 `MonitorView` / 节假日 `HolidayList` / 设备在线状态 edge-devices）SHALL 通过顶部导航的「更多/设置」折叠区访问，其功能 MUST 保持完整，仅入口位置改变。音色目录 view 与转人工任务 view 已删除——音色不在本系统编目（campaign 直接填 vendor speaker 串到 `campaign.voice_id`），转人工任务表从未被写入。无对应后端的 view（SIM 卡 / 回调记录 / 回调配置独立页）SHALL 删除；回调能力 SHALL 仅以 per-campaign「回调」tab 形式存在。

#### Scenario: 顶部入口的路由对应

- **WHEN** 用户点击顶部导航中的某个入口
- **THEN** 浏览器 URL SHALL 切换到上述路由表中对应的路径，view 内容 SHALL 仅渲染该 view 的组件

#### Scenario: 已删除入口不出现

- **WHEN** 用户浏览顶部导航与「更多/设置」折叠区
- **THEN** MUST NOT 出现「预约管理」「音色目录」「转人工任务」任一入口；访问其旧路由 SHALL 不再命中任何 view

#### Scenario: 场景详情的二级布局

- **WHEN** 用户从场景列表进入某个 campaign 详情
- **THEN** 主内容区 SHALL 显示带标题的 page header，下方分区加载基本信息与 per-campaign 配置组件

#### Scenario: 场景列表可删除场景

- **WHEN** 用户在场景列表（`/campaigns`）的某张场景卡片上触发删除
- **THEN** SHALL 弹出二次确认；确认后 SHALL 调用 `campaignsApi.delete` 删除该 campaign 并从列表移除；MUST NOT 需要进入任何运营区完成删除

### Requirement: 顶级信息架构 — 客户工作流五入口 + 模型厂商配置 + 更多折叠区

`isales-web` 管理后台 SHALL 以**单一角色的外呼工作流**组织顶层导航，不再区分运营/客户。顶部 sticky header SHALL 提供胶囊式分段控件，包含**四个主入口**（场景 / 线索 / 外呼 / 数据看板）+ **一个圆形配置按钮**（模型厂商）+ **一个「更多/设置」折叠入口**（承载低频 view）。"场景"SHALL 位于主入口序列最左，作为工作流的起点（建场景 → 灌线索 → 外呼 → 看板）。原「预约」主入口已随 change `admin-prune-vestigial-features` 删除（预约功能整体下线）。

per-campaign 的外呼策略配置不再是独立顶级入口，已并入 campaign 详情页（见 Requirement「per-campaign 外呼策略配置」）；"模型厂商"作为平台级全局凭据保留为圆形配置按钮；低频运营 view 收入「更多/设置」折叠区。SHALL NOT 存在独立的「运营管理」顶级入口或 `/operations` 落地页。

#### Scenario: 顶部导航的固定结构

- **WHEN** 用户登录后进入任意 `/` 下的子路由
- **THEN** 页面顶部 SHALL 显示固定（sticky）导航栏，左侧 logo + 标题，中间胶囊容器中 SHALL 包含四个文本+图标按钮 `[场景｜线索｜外呼｜数据看板]`，右侧 SHALL 包含一个圆形配置按钮（模型厂商）与一个「更多/设置」入口；MUST NOT 出现「运营管理」入口；MUST NOT 出现「预约」主入口

#### Scenario: 更多折叠区展开低频 view

- **WHEN** 用户打开「更多/设置」入口
- **THEN** SHALL 列出低频但可用的 view（通话监控 / 节假日 / 设备在线状态），点击任一项 SHALL 进入对应 view；MUST NOT 列出「音色目录」或「转人工任务」（两者均已删除）；视觉语言 SHALL 沿用客户面设计 token（`--isales-*`），MUST NOT 新造独立视觉系统

#### Scenario: 当前激活态视觉反馈

- **WHEN** 用户切换到任一主入口或配置入口
- **THEN** 被选中的按钮 SHALL 显示白色背景 + 主色文字 + 微阴影；其余按钮 SHALL 显示灰色文字、透明背景

#### Scenario: 移动端折叠

- **WHEN** 视口宽度 < 768px
- **THEN** 中间业务导航 SHALL 隐藏，配置入口与「更多/设置」入口 SHALL 保留可见
