## ADDED Requirements

### Requirement: restructure 角色配置卡（单条、无需 label）

campaign 配置页 SHALL 提供一张独立的 restructure（重组）角色配置卡，与 main / persona / referee / extractor 卡并列。该卡 SHALL 为 **singleton**（逻辑上单条、无「新增 / 多条」操作，形态对齐 extractor 卡），暴露 prompt 正文 + provider + model + temperature + top_p，并随既有 role_config 即时保存链路（role_config + prompt_version upsert）落库。该卡 MUST NOT 要求 label（引擎走内建路由 `restructure`，不按 label 路由），区别于 referee / persona 的 labeled 卡。

此 Requirement 把既有 Requirement「persona 角色配置（role kind）」中已声明的「restructure 与 main / referee / extractor 并列可配」从声明落到实现——此前 UI 唯一入口在未挂载的孤儿组件，部署界面进不去。

#### Scenario: 场景配置页出现 restructure 卡

- **WHEN** 用户进入某 campaign 的场景配置页
- **THEN** 页面 SHALL 渲染一张 restructure（重组）配置卡，含 prompt 正文输入 + provider / model 选择 + temperature / top_p
- **AND** 该卡为单条形态（无「新增一条」操作）

#### Scenario: 编辑并保存 restructure prompt

- **WHEN** 用户在 restructure 卡填写 prompt + 选择 provider / model 并保存
- **THEN** 系统 SHALL upsert 一条 `kind=restructure` role_config（provider 写 `ext_params.provider`、model 写 `role_config.model`）+ 其 prompt_version，并回填 `current_prompt_version_id`

#### Scenario: restructure 卡不要求 label

- **WHEN** 用户保存 restructure 卡
- **THEN** 界面 MUST NOT 把 label 作为必填项（对照 referee / persona 卡的 label 必填）
