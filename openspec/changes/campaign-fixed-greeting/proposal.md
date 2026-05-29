## Why

2026-05-29 真拨号实验把"固定开场白文案"用临时硬编码 hack 落地了——
`isales-engine/runtime_config.py` 里加了一个 `_FIXED_GREETINGS: dict[int, str] = {1: "..."}`
字典，campaign id=1 拿到固定的"您好，我是智联招聘的小雨..."25 字销售话术，跳过 LLM
开场白生成（详见 memory `project_session_2026_05_29_handoff`）。

这个 hack 已经在 ECS 真拨号 4 次实证（TTS first_byte text_len=25 完全等于这段字面），
是个**有效但不可持续**的方案：

1. 改文案需要 commit + SCP + restart engine —— 运营不能自服务
2. 只支持 campaign id=1 —— 多 campaign 扩展不了
3. 字面销售话术留在代码里 —— 技术债

**spec 层早就准备好了**：`ai-pipeline § Requirement: 开场白不走管线` 已经有 "固定模板
开场白" / "LLM 生成开场白" 两个 Scenario，明确声明 "Campaign 配置固定模板开场白 →
engine 直接 TTS 不调 LLM" 的能力。**代码 plumbing 也 75% 就绪**：

- `generate_greeting(role, config, llm, *, fixed_template=None)` 已支持 `fixed_template`
  非 None 直接返回（`isales-engine/isales_engine/pipeline/greeting.py:33-38`）
- `RuntimeConfig.fixed_greeting: str | None` 字段已存在
- `run_loop._do_greeting` 已调 `fixed_template=config.fixed_greeting`

**缺的最后 25%**：`Campaign` 表没有 `greeting` 列；`load_runtime_config` 把
`fixed_greeting` 硬编码为 None（hack 之前）或字典查找（hack 之后）；isales-web 编辑
表单没 greeting 输入框。

本 change 把这最后 25% 补齐，让 spec 已声明的能力在数据 + UI 层真正落地——hack 删除、
运营自服务、多 campaign 各自配文案。

## What Changes

- **`isales-common` Campaign 模型加 `greeting: Mapped[str | None]`**（Text 类型，nullable）
  + Pydantic schema 同步
- **新 alembic migration**：`ALTER TABLE campaign ADD COLUMN greeting TEXT`；down-migration
  `DROP COLUMN`；默认值不设（NULL semantic = "未配置 → 走 LLM 路径"）
- **`isales-engine/runtime_config.py` 删 `_FIXED_GREETINGS` 字典 hack**，改为
  `fixed_greeting: str | None = campaign.greeting`。行为完全保持——campaign 在 PG 上
  greeting 字段有值就用，NULL 就 fall back 到 `generate_greeting` LLM 路径
- **`isales-web` Campaign 编辑表单加 greeting 输入框**：`textarea` 风格 3 行，
  placeholder "留空则由 LLM 生成开场白"，跟 `STYLE_GUIDE.md` 视觉一致。**v1 不做模板
  变量替换**（`${var}` 不解析；跟同 session 反证 prompt-template-vars 不必要的方向一致）
- **`isales-api`（如需）**：campaign POST/PUT 接口 Pydantic schema 同步加 `greeting:
  str | None` 字段；实施时 audit
- **PG 数据迁移（one-time）**：migration 跑完后 ECS PG 上 `UPDATE campaign SET greeting
  = '您好，我是智联招聘的小雨，请问您现在方便接电话吗？' WHERE id = 1;` 维持
  campaign id=1 当前实验行为
- **spec delta**：
  - `data-model` MODIFIED 表归属与全表清单——campaign 行字段列表追加 `greeting`
  - `web-admin-ui` ADDED "Campaign greeting 编辑入口" Requirement
  - `ai-pipeline` **不动**（既有 "开场白不走管线" Requirement 已覆盖能力）

- **不动**：通话状态机、三层 AI 管线、cloud-edge gRPC、`call_record` schema、
  `prompt_version` / `role_config` 表、ASR/TTS provider、greeting 进 `dialog_history`
  的现有行为（仍由 `_do_greeting` 调用 `session.append_event("greeting", text=text)`
  保证）

## Capabilities

### New Capabilities

无。本 change 是现有 capabilities 的数据 + UI 层补全。

### Modified Capabilities

- `data-model`：表归属与全表清单的 campaign 行字段列表追加 `greeting` 字段。表归属
  不变（api），合规约束不变（nullable + Text）。
- `web-admin-ui`：新增 "Campaign greeting 编辑入口" Requirement——在 campaign 编辑
  表单（运营面 `/operations/campaigns/:id/edit` 或客户面 `/campaigns/:id` 的可编辑
  字段集里）加 greeting 输入控件。具体放在哪个 view 看现有 campaign 字段编辑入口
  的实施位置，实施时 audit 决定。

## Impact

**受影响代码**（跨 4 仓 + 部署侧）：

- `isales-common/isales_common/models/campaign.py` —— Campaign 模型加 `greeting` 列
- `isales-common/isales_common/schemas/campaign.py`（如有 Pydantic schema 文件）—— 同步
- 部署侧 `alembic/versions/<YYYYMMDD>_<seq>_add_campaign_greeting.py` —— 新 migration 文件
- `isales-engine/isales_engine/runtime_config.py` —— 删 `_FIXED_GREETINGS` 字典 + 读
  `campaign.greeting`
- `isales-web/<admin campaign 编辑组件>.vue` —— 加 greeting 输入框，实施时定位组件
- `isales-api/<campaign router/schema>` —— audit；如果 schema 严格那加 `greeting`
  字段透传

**API / 协议**：无契约破坏。campaign POST/PUT 是仅新增可选字段 → 客户端老版本无 greeting
字段照样能跑（NULL 即 fall back 到 LLM）。

**部署**：

1. 先跑 alembic migration（ECS PG `121.89.85.150`，规则见 `[[feedback_ecs_deploy_scp]]`
   + `[[reference_state_files]]`）
2. PG `UPDATE campaign SET greeting = '<25 字销售文案>' WHERE id = 1;` 保持当前实验
   行为
3. SCP 新 `runtime_config.py`（删 hack 后的版本）到 ECS engine
4. `systemctl restart isales-engine` + journalctl 验证启动

**顺序关键**：必须 1 → 2 → 3 → 4。倒序会让 campaign id=1 在 hack 删除后 + UPDATE 之
前那一瞬走 LLM 路径（用 ~2069 prompt_tokens + 不可控措辞，跟期望行为不一致）。

**联合验收**：mac dev DingRTC 真拨号验证——TTS first_byte text_len=25（跟当前 hack
状态一致）即视为通过。

**不受影响**：

- isales-scheduler / isales-worker / isales-telephony（无依赖 campaign.greeting）
- ECS engine session 状态机、cloud-edge gRPC、call_record / pipeline_trace schema
- 已 archive 的 `engine-judge-dialog-context`（chat-history 那半）—— 完全正交
