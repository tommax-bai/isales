## RENAMED Requirements

- FROM: `### Requirement: 顶级信息架构 — 客户工作流四入口 + 模型厂商配置`
- TO: `### Requirement: 顶级信息架构 — 客户工作流五入口 + 模型厂商配置 + 更多折叠区`

## REMOVED Requirements

### Requirement: 运营面 view 收纳

**Reason**: 系统只有一个角色（所有登录用户都是「用户」），不存在「运营 vs 客户」两类受众。独立的运营管理区与 `OperationsIndex` 落地页是这条二分假设的载体，与单角色模型冲突，整体解散。

**Migration**: 原运营 view 按能力归位到统一的客户面导航：数据看板升为顶级入口（见「顶级信息架构」MODIFIED）；通话监控 / 转人工任务 / 节假日 / 设备在线状态 / 音色目录（后端均已实装）收入顶部导航的「更多/设置」折叠区；SIM 卡 / 回调记录 / 回调配置独立页（无对应后端）删除，回调收口为 per-campaign「回调」tab；任务管理与场景列表重复，删除（场景列表补「删除场景」入口承接）。campaign 全字段高级编辑作为引擎重设计期的临时例外保留，改由场景详情进入（见「campaign 客户向管理 view」MODIFIED）。旧运营路由的 301 兼容项一并清理。

## MODIFIED Requirements

### Requirement: 客户面 view 清单

`isales-web` SHALL 实现以下客户视角 view（系统单一角色，所有 view 同属「用户」工作台，无运营/客户分区）：

| 入口 | 路由 | view 文件 |
|---|---|---|
| 场景管理 | `/campaigns` | `views/Campaigns/CampaignWorkspace.vue` |
| 场景详情 | `/campaigns/:id` | `views/Campaigns/CampaignDetail.vue` |
| 线索管理 | `/leads` | `views/Leads/LeadList.vue` |
| 外呼记录 | `/calls` | `views/Calls/CallList.vue` + `views/Calls/CallDetail.vue` |
| 预约管理 | `/appointments` | `views/Appointments/AppointmentList.vue` |
| 数据看板 | `/dashboard` | `views/DashboardView.vue`（由运营区升为客户顶级入口） |
| 模型厂商 | `/config/model-providers` | `views/Config/ModelProviderConfig.vue` |

低频但后端已实装的 view（通话监控 `MonitorView` / 转人工任务 `HandoffTaskList` / 节假日 `HolidayList` / 设备在线状态 edge-devices / 音色目录 `VoiceModelList`）SHALL 通过顶部导航的「更多/设置」折叠区访问，其功能 MUST 保持完整，仅入口位置改变。音色目录 SHALL 同时作为 campaign `voice_id` 选择/试听目录暴露。无对应后端的 view（SIM 卡 / 回调记录 / 回调配置独立页）SHALL 删除；回调能力 SHALL 仅以 per-campaign「回调」tab 形式存在。

#### Scenario: 顶部入口的路由对应

- **WHEN** 用户点击顶部导航中的某个入口
- **THEN** 浏览器 URL SHALL 切换到上述路由表中对应的路径，view 内容 SHALL 仅渲染该 view 的组件

#### Scenario: 场景详情的二级布局

- **WHEN** 用户从场景列表进入某个 campaign 详情
- **THEN** 主内容区 SHALL 显示带标题的 page header，下方分区加载基本信息与 per-campaign 配置组件

#### Scenario: 场景列表可删除场景

- **WHEN** 用户在场景列表（`/campaigns`）的某张场景卡片上触发删除
- **THEN** SHALL 弹出二次确认；确认后 SHALL 调用 `campaignsApi.delete` 删除该 campaign 并从列表移除；MUST NOT 需要进入任何运营区完成删除

### Requirement: 顶级信息架构 — 客户工作流五入口 + 模型厂商配置 + 更多折叠区

`isales-web` 管理后台 SHALL 以**单一角色的外呼工作流**组织顶层导航，不再区分运营/客户。顶部 sticky header SHALL 提供胶囊式分段控件，包含**五个主入口**（场景 / 线索 / 外呼 / 预约 / 数据看板）+ **一个圆形配置按钮**（模型厂商）+ **一个「更多/设置」折叠入口**（承载低频 view）。"场景"SHALL 位于主入口序列最左，作为工作流的起点（建场景 → 灌线索 → 外呼 → 收预约 → 看板）。

per-campaign 的外呼策略配置不再是独立顶级入口，已并入 campaign 详情页（见 Requirement「per-campaign 外呼策略配置」）；"模型厂商"作为平台级全局凭据保留为圆形配置按钮；低频运营 view 收入「更多/设置」折叠区。SHALL NOT 存在独立的「运营管理」顶级入口或 `/operations` 落地页。

#### Scenario: 顶部导航的固定结构

- **WHEN** 用户登录后进入任意 `/` 下的子路由
- **THEN** 页面顶部 SHALL 显示固定（sticky）导航栏，左侧 logo + 标题，中间胶囊容器中 SHALL 包含五个文本+图标按钮 `[场景｜线索｜外呼｜预约｜数据看板]`，右侧 SHALL 包含一个圆形配置按钮（模型厂商）与一个「更多/设置」入口；MUST NOT 出现「运营管理」入口

#### Scenario: 更多折叠区展开低频 view

- **WHEN** 用户打开「更多/设置」入口
- **THEN** SHALL 列出低频但可用的 view（通话监控 / 转人工任务 / 节假日 / 设备在线状态 / 音色目录），点击任一项 SHALL 进入对应 view；视觉语言 SHALL 沿用客户面设计 token（`--isales-*`），MUST NOT 新造独立视觉系统

#### Scenario: 当前激活态视觉反馈

- **WHEN** 用户切换到任一主入口或配置入口
- **THEN** 被选中的按钮 SHALL 显示白色背景 + 主色文字 + 微阴影；其余按钮 SHALL 显示灰色文字、透明背景

#### Scenario: 移动端折叠

- **WHEN** 视口宽度 < 768px
- **THEN** 中间业务导航 SHALL 隐藏，配置入口与「更多/设置」入口 SHALL 保留可见

### Requirement: campaign 客户向管理 view

`isales-web` SHALL 提供 campaign（外呼"场景"）的列表与详情 view，使用户无需进入任何独立分区即可创建、配置、启停、删除 campaign。campaign 全字段高级编辑（`CampaignEdit.vue`）作为**引擎重设计期的临时例外**保留，改由场景详情进入（不再属于已解散的运营区），待引擎定型后由后续 change 按客户面理念折叠重做。

#### Scenario: 场景列表

- **WHEN** 用户点击顶部导航"场景"入口（`/campaigns`）
- **THEN** SHALL 显示 campaign 卡片列表，每卡 SHALL 显示场景名称、启停状态徽标、归属线索数、外呼进度概览；列表顶部 SHALL 提供"新建场景"入口，每卡 SHALL 提供删除入口

#### Scenario: 场景详情

- **WHEN** 用户点击某个 campaign 卡片（`/campaigns/:id`）
- **THEN** SHALL 进入该 campaign 的详情 view，展示基本信息 + per-campaign 外呼策略配置区 + 启停控制 + 外呼进度

#### Scenario: 高级编辑从场景详情进入

- **WHEN** 用户在 campaign 详情 view 需要编辑客户面未直出的高级行为字段（静音 / 打断 / 转人工 / 重试 等）
- **THEN** SHALL 从场景详情进入保留的全字段高级编辑器；该入口 MUST NOT 经由任何 `/operations` 路由或「运营管理」菜单
