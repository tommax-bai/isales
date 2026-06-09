## Why

引擎侧 persona 多人设推测对话（gate-first 门控选一）早已 archived 上线（`2026-06-08-engine-tools-multidialogue-gating`），`campaign.persona_fanout_cap` 字段、persona 角色的 CRUD、delete-guard、`routing_rule_unknown_persona` 校验后端全部就绪——但前端**至今没有创建 persona 的入口**：上一次 web 改版（active `web-admin-scene-single-page-config`）把 RoleConfigTab 弃用后，明文 defer 了 persona/restructure 配置卡（"默认 N=1 用不到，后续真用再补同款卡"）。同时 main 角色卡当前与 referee/extractor **同构**（给了 name 字段 + enable 开关 + 增删动作），违反 data-model「main 每 campaign 必有且唯一」不变量。本 change 兑现那张被 defer 的 persona 卡，并把 main 卡特殊化收口。

## What Changes

- **兑现 persona 配置卡**（web-admin-ui）：在 campaign 详情页「多流路由」配置区补「人设列表」内联小节——可增删 N 个 `kind=persona` 角色，每行编辑 `label`（campaign 内唯一、必填）/ model / prompt，复用 referee 列表同款卡模式。落 `kind=persona` role_config（消费已实装的 admin API）。
- **persona_fanout_cap 控件**（web-admin-ui）：在「多流路由」小节提供推测并发上限控件（数字选择器，clamp [1,3]，`1` = 关、仅 main 无推测），经 campaign PATCH 持久化（字段后端已暴露）。启用的对话路由总数（main + persona）超过 cap 时 UI 提示并阻止超额启用。
- **persona 删除前置校验提示**（web-admin-ui）：删除被 `routing_rules` route action 引用的 persona 时，UI 先提示"先改规则"（对应后端已实装的 `routing_rule_unknown_persona` 422 delete-guard），不直接吞 422。
- **main 角色卡特殊化**（web-admin-ui，**修正现有 spec 不自洽**）：main 卡 MUST NOT 提供 enable 开关、删除、新增第二个；name/label 字段对 main 隐藏或锁死（main 不进路由表，label 对它冗余）。referee/extractor 维持原可增删/可禁用行为不变。

## Capabilities

### New Capabilities
<!-- 无新增 capability —— 纯前端兑现已设计好的 web-admin-ui 配置能力 + 收口 main 卡约束。 -->

### Modified Capabilities
- `web-admin-ui`: 「多流路由」配置区的 persona 列表卡 + `persona_fanout_cap` 控件由"已设计、未实装"改为实装可用；main 角色卡由"与 referee/extractor 同构（可命名/可禁用/可增删）"收紧为"单条、必有、不可禁用/删除/新增、名字锁死"。无后端 / 数据契约行为变更。

## Impact

- **isales-web**（唯一受影响仓）：`views/Campaigns/CampaignDetail.vue`「多流路由」小节新增 persona 列表 + `persona_fanout_cap` 控件；persona 行编辑/删除组件（复用 referee 列表同款卡）；main 角色卡（PromptTier 卡）去 enable 开关 / 删除 / 新增、锁名字。
- **后端无改动**（已核实）：`persona_fanout_cap` 已在 `CampaignUpdate`（`isales-common/.../schemas/campaign.py:128`）+ api schemas 暴露，PATCH 直接可写；persona delete-guard 已实装（`isales-api/.../routing_validation.py:113` + `routers/role_configs.py:172`）。**无 alembic / engine 改动。**
- **部署**：web only（`npm run build` → `rsync -az --delete dist/` → nginx reload）。
- **关联 active changes**：叠在 `web-admin-scene-single-page-config`（单页配置骨架）之上、兑现其 defer 缺口；referee 显示名正由 `engine-gate-supervision-rename` 改为「门控监管」（display-only），本 change spec 措辞与之兼容、不回退命名。
- **风险低**：opt-in，默认 `persona_fanout_cap=1` 行为不变，存量 campaign 向后兼容。
