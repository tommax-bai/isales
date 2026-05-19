## ADDED Requirements

### Requirement: 顶级信息架构 — 客户工作流三入口 + 配置三按钮

`isales-web` 管理后台 SHALL 以**客户外呼工作流**而非后端服务边界组织顶层导航。顶部 sticky header SHALL 提供胶囊式分段控件，包含三个主入口（线索 / 外呼 / 预约）+ 三个圆形配置按钮（AI 外呼配置 / ASR-TTS 通路 / 模型厂商）。原侧边栏布局（`DefaultLayout` 的左侧菜单）SHALL 移除。

#### Scenario: 顶部导航的固定结构

- **WHEN** 用户登录后进入任意 `/` 下的子路由
- **THEN** 页面顶部 SHALL 显示固定（sticky）导航栏，左侧 logo + 标题"客户外呼系统"，中间胶囊容器中 SHALL 仅包含三个文本+图标按钮 `[线索管理｜外呼记录｜预约管理]`，右侧胶囊容器中 SHALL 仅包含三个圆形图标按钮（齿轮 / 波形 / 钥匙）

#### Scenario: 当前激活态视觉反馈

- **WHEN** 用户切换到任一主入口或配置入口
- **THEN** 被选中的按钮 SHALL 显示白色背景 + 主色文字 + 微阴影；其余按钮 SHALL 显示灰色文字、透明背景

#### Scenario: 移动端折叠

- **WHEN** 视口宽度 < 768px
- **THEN** 中间业务导航 SHALL 隐藏，配置入口 SHALL 保留可见

### Requirement: 客户面 view 清单

`isales-web` SHALL 实现以下 6 个客户视角 view，每个 view 对应顶部导航中的一个入口：

| 入口 | 路由 | view 文件 |
|---|---|---|
| 线索管理 | `/leads` | `views/Leads/LeadList.vue`（重做） |
| 外呼记录 | `/calls` | `views/Calls/CallList.vue`（重做） + `views/Calls/CallDetail.vue` |
| 预约管理 | `/appointments` | `views/Appointments/AppointmentList.vue`（新增） |
| AI 外呼配置 | `/config/ai-call` | `views/Config/AICallConfig.vue`（新增） |
| ASR/TTS 通路 | `/config/voice-channels` | `views/Config/VoiceChannelConfig.vue`（新增） |
| 模型厂商 | `/config/model-providers` | `views/Config/ModelProviderConfig.vue`（新增） |

#### Scenario: 顶部入口的路由对应

- **WHEN** 用户点击顶部导航中的某个入口
- **THEN** 浏览器 URL SHALL 切换到上述路由表中对应的路径，view 内容 SHALL 仅渲染该 view 的组件

#### Scenario: 配置入口的二级布局

- **WHEN** 用户点击三个配置圆按钮之一
- **THEN** 主内容区 SHALL 显示带 icon + 标题 + 副标题的 page header，下方加载对应的配置组件

### Requirement: 运营面 view 收纳

非客户工作流的运营管理 view（数据看板 / 任务管理 / 通话监控 / 回调配置 / 回调记录 / 转人工任务 / 节假日 / 设备 / SIM 卡）SHALL 通过顶部导航的 overflow 子菜单（或独立的 `/operations` 子区索引页）访问。这些 view 的功能 MUST 保持完整，仅入口位置改变。

#### Scenario: 收纳后的 view 仍可访问

- **WHEN** 用户从顶部导航打开 overflow 菜单或访问 `/operations`
- **THEN** SHALL 看到完整的运营 view 列表（Dashboard / Campaigns / Monitor / Callback Configs / Callback Logs / Handoff Tasks / Holidays / Devices / SIM Cards），点击任一链接 SHALL 进入对应 view

#### Scenario: 路由迁移

- **WHEN** 用户访问旧的运营路由（`/dashboard`, `/campaigns`, `/devices`, `/sim-cards`, `/holidays`, `/callback-configs`, `/callback-logs`, `/handoff-tasks`, `/monitor/:id`）
- **THEN** 服务 SHALL 永久重定向（301 等价的客户端 `router.beforeEach` 重定向）到 `/operations/<原路径>`，保留旧链接可用性

### Requirement: 已 spec 能力的 UI 暴露

`isales-web` SHALL 在新 view 中暴露以下 backend 已 spec 但当前 UI 未提供的能力：

- 多并行 prompt 配置（`role-prompt`、`filler`、`goal-achievement`、`ai-pipeline` spec 已支持 N 条配置并行）— 在 AI 外呼配置 view 中按 4 个 tier（对话策略 / 垫词 / 质量判别 / 润色）分组，每 tier 提供 N 条配置的增删改 + enable switch + temperature/topP 滑杆 + provider/model 选择器
- ASR/TTS provider 管理（`provider-abc` spec）— 在 ASR/TTS 通路 view 中提供 ASR 配置列表、TTS 配置列表、音色库列表，各自支持 enable switch 与字段编辑
- 模型厂商 API key 管理（`provider-abc` spec）— 在模型厂商 view 中按 provider（OpenAI / Anthropic / Azure / Google）分卡片展示，每卡片含 API key 密码输入（带显示/隐藏 toggle 与掩码预览）+ endpoint 输入 + organization id（OpenAI 限定）+ enable switch + 状态徽标
- 可通话时段配置（`time-window` spec）— 在 AI 外呼配置 view 中以多个时段卡片形式列出，每段含开始时间、结束时间、周一至周日的 7 个 checkbox
- ASR 完整对话内容（`transcript` spec 已有 `transcript` JSONB）— 在外呼记录 view 的每条记录上以可折叠（Collapsible）面板展示，AI 与客户消息 SHALL 用左右气泡区分
- 目标达成评分（`goal-achievement` spec 已有 `call_summary.goal_achieved` + 可扩展字段）— 在外呼记录卡片中展示评分（0–100）、客户意向（高/中/低/无）、是否成功预约、已覆盖的关键要点列表

#### Scenario: 多并行 prompt 编辑

- **WHEN** 用户在 AI 外呼配置 view 添加一条新的对话策略
- **THEN** 表单 SHALL 提供 name / model provider / model name / temperature(0–2) / topP(0–1) / prompt 文本（多行）/ enable 开关；保存后 SHALL 通过 admin API 写入对应 `role_config` + `prompt_version`

#### Scenario: API Key 显示与掩码

- **WHEN** 用户进入模型厂商配置 view 且某 provider 已配置 API key
- **THEN** 输入框默认 type=password；输入框下方 SHALL 显示掩码预览（前 4 位 + ●●●●●●●● + 后 4 位）；点击眼睛图标后 SHALL 切换 input type 为 text 并隐藏掩码预览

#### Scenario: 通话气泡显示

- **WHEN** 用户在外呼记录中点击"查看通话内容"
- **THEN** SHALL 展开 collapsible 区域，按 transcript 顺序逐条渲染气泡，AI 消息靠左（蓝色背景），客户消息靠右（绿色背景），气泡上方 SHALL 显示角色标签

### Requirement: 设计 token 与主题

`isales-web` SHALL 引入独立的 `src/styles/design-tokens.css` 文件承载设计 token，并通过 Element Plus SCSS theme override 与 CSS variable 注入将 token 应用到组件。token SHALL 包含 Figma 设计稿中的色彩、圆角、字号、字重定义。

#### Scenario: 主色 token

- **WHEN** 应用 token
- **THEN** `--isales-primary` SHALL 等于 `#030213`，`--isales-radius` SHALL 等于 `0.625rem`，`--isales-font-size-base` SHALL 等于 `16px`

#### Scenario: 状态色 token

- **WHEN** 渲染线索状态、外呼结果、预约状态、客户意向等 badge
- **THEN** SHALL 使用 token 中定义的语义色（new=blue, contacted=yellow, interested=green, appointed=purple, visited=gray, lost=red 等），各色 SHALL 同时有 100/700/800 三档（背景 / 边框 / 文字）

#### Scenario: 暗色主题预留

- **WHEN** 当前阶段
- **THEN** design-tokens.css MUST 同时定义 `:root` 与 `.dark` 两组变量；但 `.dark` SHALL NOT 被自动激活（v1.0 范围内仅亮色），等后续 change 单独引入主题切换

### Requirement: 图标库切换

被重做的 6 个客户面 view + 新顶部导航 SHALL 使用 `lucide-vue-next` 图标库。未被重做的运营 view 可继续使用 `@element-plus/icons-vue`。

#### Scenario: 客户面 view 的图标

- **WHEN** 任一客户面 view 渲染图标
- **THEN** 图标组件 SHALL 来自 `lucide-vue-next`（如 `Phone`, `Users`, `Calendar`, `Settings`, `Key`, `Waves`, `LayoutGrid`, `Mic`, `Volume2`, `Music`, `Target`, `CheckCircle`, `XCircle`, `MessageSquare`, `Plus`, `Trash2`, `Save`, `Edit`, `Eye`, `EyeOff` 等）

#### Scenario: 依赖管理

- **WHEN** 添加 `lucide-vue-next` 依赖
- **THEN** `isales-web/package.json` SHALL 新增该依赖；MUST NOT 同时移除 `@element-plus/icons-vue`（运营 view 仍在用）
