## ADDED Requirements

### Requirement: Campaign greeting 编辑入口

isales-web MUST 在 campaign 编辑表单提供 greeting 字段编辑控件，让运营人员可输入 /
修改 / 清空 campaign-level 固定开场白文案。保存后下次该 campaign 发起 dial 时 engine
SHALL 通过 `load_runtime_config` 拿到新文案，MUST NOT 需要 engine 重启。控件位置（客
户面 CampaignDetail.vue 或运营面 `/operations/campaigns/:id/edit`）由实施 task 阶段
audit 决定。

#### Scenario: 表单包含 greeting 输入控件

- **WHEN** 运营人员打开 campaign 编辑表单
- **THEN** 表单 MUST 含 "开场白文案" 字段；控件类型 SHALL 是 textarea（推荐 3 行
  高度）；MUST 含 placeholder "留空则由 LLM 生成开场白" 提示留空行为；视觉风格
  MUST 跟 `STYLE_GUIDE.md` 一致（label / textarea 间距 / token 同其他字段）

#### Scenario: 保存空文案等价 NULL

- **WHEN** 运营人员把 greeting 字段留空 / 删空后保存
- **THEN** isales-web 在提交到 isales-api 前 SHOULD 把空字符串 normalize 为 NULL
  （或者依赖后端 isales-api 把空串归为 NULL）；最终 PG `campaign.greeting` 字段
  MUST 是 NULL 而非空串，让 engine 走 `generate_greeting` LLM 路径

#### Scenario: 保存非空文案立即影响下次 dial

- **WHEN** 运营人员保存 greeting 字段为非空文案
- **THEN** PG `campaign.greeting` 字段 MUST 是该字面文本；isales-engine 下次该
  campaign 的 dial 触发 `load_runtime_config` 时 MUST 直接读到新文案；engine MUST
  跳过 LLM 直接 TTS 该文案；MUST NOT 需要 engine 重启或 cache invalidation

#### Scenario: v1 不支持模板变量

- **WHEN** 运营人员在 greeting 字段写 `${lead_name}` 等占位符字面
- **THEN** isales-web SHALL NOT 警告或拒绝保存；isales-engine SHALL 把占位符字面
  字符串直接送 TTS；v1 SHALL NOT 解析任何 `${var}` 模板变量。模板变量支持留待
  future change

#### Scenario: greeting 字段与 ai-pipeline 既有 Requirement 协同

- **WHEN** Campaign 配置了非空 greeting
- **THEN** engine 行为 MUST 跟 `ai-pipeline § Requirement: 开场白不走管线 §
  Scenario: 固定模板开场白` 一致（直接 TTS 播放 greeting，不调任何 LLM）；本
  Requirement MUST NOT 改变开场白入 dialog_history 的行为（仍按 `ai-pipeline §
  Scenario: 开场白记入对话历史` 处理）
