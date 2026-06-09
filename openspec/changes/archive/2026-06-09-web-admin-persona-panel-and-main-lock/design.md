## Context

引擎 gate-first 多人设推测对话已上线（`2026-06-08-engine-tools-multidialogue-gating` archived）。一轮 PROCESSING 里 `min(1 + enabled_persona, persona_fanout_cap)` 条对话路由（含 main）eager 并行起跑、缓冲首句，门控监管（kind=referee）按用户输入分类经 `routing_rules`（first-match-wins）选中**一条**放行、`cancel()` 其余（`run_loop.py:_run_gated_turn` 1234 起）。

后端能力已全部就绪（本 change 已核实）：
- `campaign.persona_fanout_cap` int 字段，default 1，clamp [1,3]，已在 model（`isales-common/.../models/campaign.py:66`）、`CampaignBase`（schemas/campaign.py:43）、`CampaignUpdate`（schemas/campaign.py:128，`int | None`）暴露 → campaign PATCH 直接可写。
- persona 角色 CRUD 走通用 `role_config` 端点（kind=persona）。
- persona delete-guard 已实装：被 `routing_rules` route action 引用时拒删，返回 422 `routing_rule_unknown_persona`（`isales-api/.../routing_validation.py:113` + `routers/role_configs.py:172`）。

缺口在前端：上一次 web 改版（active `web-admin-scene-single-page-config`）弃用 RoleConfigTab 后，明文 defer 了 persona/restructure 配置入口（"默认 N=1 用不到，后续真用再补同款卡"）。同时历史 spec 把 main / referee / extractor 三个角色卡**同构**呈现（同一张表单都给 name + enable 开关 + 增删），与 data-model「main 每 campaign 必有且唯一、且 mandatory」不变量自相矛盾。

## Goals / Non-Goals

**Goals:**
- 在 campaign 详情页「多流路由」配置区兑现 persona 列表卡（增删 N 个 kind=persona，编辑 label/model/prompt），复用 referee 列表同款卡模式。
- 提供 `persona_fanout_cap` 配置控件（[1,3]，1=关），经 campaign PATCH 持久化。
- 删除被 `routing_rules` 引用的 persona 时，前端先给"先改规则"提示（友好化已实装的 422 delete-guard）。
- 把 main 角色卡特殊化：不可禁用、不可删除、不可新增第二个、name 字段锁死/隐藏。

**Non-Goals:**
- 不动 api / engine / 数据契约（后端已就绪，纯消费）。
- 不实装 restructure 配置卡（同属 defer 缺口，但本 change 只兑现 persona；restructure 留后续）。
- 不改 referee→门控监管 的显示文案（那是 active `engine-gate-supervision-rename` 的范围；本 change 与其兼容、不回退命名）。
- 不引入新的 persona-specific 端点或 schema。

## Decisions

### D1: persona 列表卡复用 referee 列表同款卡，不新建组件族
persona 与 referee 在 UI 上同构（都是 N 个、可增删、每行 label/model/prompt），落库都走通用 `role_config`（仅 kind 不同）。复用现有裁判列表编辑器（参数化 `kind`），避免双份组件。**备选**：为 persona 新建独立组件 → 否决（重复代码、违背"避免多层兜底/重复"原则）。persona 行的 prompt 编辑器提示文案为人设话术导向（"这是一套可被门控选中的对话话术/语气"），与 referee 的"输出单个 category 词"提示区分。

### D2: `persona_fanout_cap` 控件放「多流路由」小节头部，数字步进器 [1,3]
cap 是 campaign 级字段（非 role_config），放在 persona 列表上方作为该小节的总开关语义：`1` = 关（仅 main、无推测），`2/3` = 开。经 campaign PATCH 持久化（字段已暴露）。UI 在「启用对话路由总数（main + 已 enable persona）> cap」时提示并阻止超额 enable（对应 spec 既有「persona 数量提示 cap」scenario）。**备选**：独立 boolean toggle + 隐藏数字 → 否决（cap 本身既是开关又是上限，多一个 boolean 是冗余状态、易不一致）。

### D3: main 卡特殊化用「锁定」prop，不复制出独立 MainCard
给现有角色卡（PromptTier 卡）传 `locked`/`isMain` 语义 prop：渲染时隐藏 enable 开关（恒 on）、不渲染删除/新增、name 字段 readonly 或隐藏。referee/extractor 卡不传该 prop，行为不变。**备选**：抽出独立 `MainRoleCard.vue` → 否决（与 referee/extractor 卡 90% 重叠，重复维护）。

### D4: spec delta 用 ADDED 不用 MODIFIED（避开 in-flight 改名 change 撞段）
active `engine-gate-supervision-rename` 正 MODIFY「三 LLM prompt 编辑（per-campaign）」等 scenario（referee→门控监管显示名）。若本 change 也 MODIFY 同一批 scenario 去给 main 加约束，两个 change archive 时会因同块基线漂移而 silent-fail（见 [[feedback_openspec_archive_silent_failure]]）。故本 change 的 main-lock 落成一条**新的、更具体的** ADDED requirement，文中显式声明「对 kind=main，本约束 SHALL 覆盖泛化的三角色同构处理」——更具体者优先，archive 时只追加、不碰改名 change 的基线。persona 列表卡本身已被 spec §「campaign 多流路由配置界面」⑤ + §「persona 角色配置（role kind）」覆盖，无需重复 spec，纯 tasks 兑现；net-new 仅「fanout_cap 配置控件」一条 ADDED。

### D5: delete-guard 前端友好化 + 客户端预检
删除 persona 前，前端先用已加载的 `routing_rules` 做客户端预检：若有 route action `to == 该 persona label`，直接提示"先在路由规则里移除对它的引用"，不发请求；万一漏检，后端 422 `routing_rule_unknown_persona` 仍兜底，前端把它翻成同一句可读提示（不暴露裸错误码）。

## Risks / Trade-offs

- [叠在 active `web-admin-scene-single-page-config` 之上，依赖其「多流路由」内联小节骨架] → 若该 change 尚未实装/archive，persona 小节插入点可能不存在。Mitigation：apply 阶段先确认单页配置骨架是否已落地；未落地则本 change 的 persona 小节就近挂到现有「多流路由配置界面」要求所对应的组件，二者都 web-only、无契约冲突。
- [与 `engine-gate-supervision-rename` 并发触及 web-admin-ui spec] → Mitigation：见 D4，ADDED-only，不碰其 MODIFIED 基线；实装文案用 referee/门控监管 中性表述、不与改名打架。
- [main 卡「锁 name」可能与历史落库的 main role_config.name 字段不一致] → Mitigation：仅前端隐藏/只读编辑，不删字段、不改库；已有 name 值保留，只是不再可编辑。
- [两套存储模式并存：persona 走 role_config 自存、cap 走 campaign PATCH] → 与现有 referee/filler 卡一致，非本 change 新引入；保存边界沿用现状。
