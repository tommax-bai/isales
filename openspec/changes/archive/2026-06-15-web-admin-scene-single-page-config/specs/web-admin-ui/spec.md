## ADDED Requirements

### Requirement: 场景配置一页到底

场景(campaign)的全部 per-campaign 设置能力 SHALL 铺排在**单一**场景详情 view(`/campaigns/:id`,`CampaignDetail.vue`)内,**纵向全展开、一页到底**;MUST NOT 再提供独立的多-tab 高级编辑器或跨页「高级配置」跳转。场景详情即场景的唯一配置入口(单角色)。

页面 SHALL 按以下顺序纵向铺排小节:进度 → 基本信息(含 greeting TTS 试听) → 可拨时段 → AI 角色(main / referee / extractor 三个角色卡 + 垫词集合) → 多流路由 → 工具触发 → 沉默激活 → 打断保护 → 转人工 → 收尾 → 重试·跟进 → 勿打 → 回调 → 保存条。

保存模型 SHALL 兼容两类:**AI 角色卡与垫词集合各自即时保存**(按 campaign-id 自包含);**其余 form-driven 小节经页面底部统一保存条提交**(一次 `campaignsApi.update`)。保存条文案 SHALL 说明这一区分。

#### Scenario: 单页配置无跳转

- **WHEN** 用户从场景列表进入某个 campaign 详情
- **THEN** 该 view SHALL 在同一页内暴露全部 per-campaign 配置能力(基本/时段/AI 角色/路由/工具触发/沉默/打断/转人工/收尾/重试·跟进/勿打/回调);MUST NOT 显示「高级配置」跳转按钮;MUST NOT 存在独立的 `operations-campaign-edit`(或等价)高级编辑器路由

#### Scenario: 旧高级编辑器路由已移除

- **WHEN** 用户访问旧的 `/operations/campaigns/:id/edit` 链接
- **THEN** 路由 SHALL 不再存在(走 not-found,运营区已解散、无重定向);场景的全字段编辑改在场景详情单页完成

#### Scenario: 两类保存并存

- **WHEN** 用户在场景详情页修改了「基本信息 / 路由 / 工具触发 / 沉默 / 转人工 / 收尾 / 调度」等 form-driven 字段
- **THEN** 这些改动 SHALL 经底部统一保存条一次提交(`campaignsApi.update`),422 字段校验错误 SHALL 标红对应字段;而 AI 角色卡 / 垫词集合的改动各自有独立即时保存,不经该保存条

#### Scenario: greeting 试听保留

- **WHEN** 用户在基本信息小节填写了 greeting 且选择了音色
- **THEN** SHALL 提供 greeting TTS 试听能力(单页折叠不得丢失该能力)
