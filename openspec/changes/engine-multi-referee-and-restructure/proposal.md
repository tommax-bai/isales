## Why

`pipeline-stream-and-referee` 把 pipeline 收敛为「main 流式 + 单 referee 旁路决策」，单 referee 用一条 `{decision, goal_type, confidence}` 同时承担「意图判断 / 拒绝识别 / 转人工 / 目标达成」多个正交职责——耦合在一个 prompt 里，任意一维改语义都要动整条 prompt，且决策只能输出 4 个固定枚举，扩不出新维度。同时当前架构对「用户没接住 / 被 barge-in 打断 / referee 拿不准」这三类「这一轮 AI 不该生成全新内容、而应换个口语化说法把上一句重说一遍」的场景没有处置：要么硬接、要么丢弃、要么误触发状态转移。参考产品 voxen（`~/codes/voxen-main`）的实证架构已证明「多裁判并行 + 路由规则表 + 重组流」能干净地解这两个问题。

## What Changes

### 多裁判并行 + 路由规则（升级现有单 referee）

- **BREAKING** `role_config.kind=referee` 从「每 campaign 恰好 1 行」放宽为「可配 N 行」：每个 referee 有独立 system prompt + 独立输出枚举语义（如一个判 `POSITIVE/NEGATIVE`、一个判 `OFFENSIVE/REJECT/OPERATOR/NEUTRAL`），仍用便宜小模型、JSON/分类输出、与 main LLM 并行 spawn。
- **新增** 「路由规则表」配置：每条规则 `{referee, matching_value → action}`，action ∈ {状态转移（transfer/goal_achieved/customer_decline）, 切某条 main/restructure stream}。engine 收齐 N 个 referee 输出后由 decider 按规则**级联匹配，第一个命中即生效**。
- **向后兼容**：只配 1 个 referee + 一组内置默认规则（`continue/goal_achieved/customer_decline/transfer`）时，行为等价于 `pipeline-stream-and-referee` 的单 referee 现状，不破坏已有 campaign。
- engine：PROCESSING 入口 `asyncio.gather` 并行 spawn N referee，收齐后跑规则引擎决定 routing；保留 fail-open（全部 referee 超时/非法/低置信 → 默认 `continue`）。

### 重组流 restructure（新增）

- **新增** `role_config.kind=restructure`：用 rewrite/包装 prompt（「口语化重新包装当前句子，可换顺序/用词不改含义，开头加过渡衔接词」），输入是 **InterruptText**（被打断残留内容 / 上一句 AI 要点）而非「用户最新一句 + 对话历史」，输出仍流式喂 TTS。
- **新增** engine `InterruptText` 会话状态：暂存「被 barge-in 打断时 main 残留未说完的内容」或「上一句 AI 要点」。
- 三种触发场景（均由「某 referee 判定 + 路由规则命中」或「主 referee 低置信」驱动，不新增独立兜底层）：
  - **(a) 用户没接住 / 答非所问**：某 referee 判无意义（NEGATIVE 类）→ 规则命中切 restructure，把上一句要点换口语化重说。
  - **(b) barge-in 被打断后重说**：用户打断 AI 后 engine 把残留内容存为 InterruptText，下一轮切 restructure 重组成顺畅一句补上，而非丢弃或硬接。
  - **(c) 主裁判低置信兜底**：主 referee `confidence < 阈值` 拿不准走哪个状态时，先切 restructure 口语化复述上一句拖一轮，等下一轮再判定（替代「低置信直接 continue 静默」）。

### 数据契约改动（BREAKING）

- **BREAKING** `role_config.kind` 枚举增加 `restructure`；`kind=referee` 唯一性约束放宽（per-campaign 允许多行）。
- **新增** 路由规则 schema（campaign 维度，规则有序列表）。承载方式（JSONB vs 新表）在 design.md 定。
- **BREAKING** `pipeline_trace`：`referee_decision`/`referee_goal_type`/`referee_duration_ms` 单值字段改为承载 **N 个 referee 结果**（list/JSONB）；新增 `matched_rule` / `restructure_active` / `restructure_trigger`（a/b/c）记录字段。
- **BREAKING** `call_record.prompt_versions` JSONB：`referee_llm` 单值改为 `referee_llms[]`，新增 `restructure_llm`。

### Web admin（BREAKING）

- **BREAKING** campaign 配置页改为 voxen「多流路由」式界面：主对话流 + 重组流 + N 个裁判 + 路由规则编辑（referee → 匹配值 → 动作）。
- referee 配置从「单行」改为「可增删的列表」；新增 restructure prompt 编辑入口。

### 历史 change housekeeping

- 本 change **依赖** active change `pipeline-stream-and-referee`：理想实施顺序是 `pipeline-stream-and-referee` 先跑完剩余 task + `openspec validate --strict` + archive，再实施本 change（避免两个 active change 同时改 ai-pipeline / data-model / role-prompt 的 delta 互相覆盖）。proposal 把这条依赖显式记录在此。

## Capabilities

### New Capabilities

无。多裁判路由与重组流均属 `ai-pipeline` capability 的内部成分；路由规则配置走现有 `data-model` + `web-admin-ui` 契约。

### Modified Capabilities

- `ai-pipeline`: § "referee LLM 二级决策" 重写为「多 referee 并行 + decider 规则引擎」；新增 § "重组流 restructure"（三触发场景 + InterruptText + 与现有 fail-open/filler 的职责边界）。
- `role-prompt`: § "referee prompt 内容规范" 改为「每个 referee 独立 prompt + 独立枚举语义」；新增 § "restructure/rewrite prompt 规范"。
- `data-model`: § "role_config.kind 枚举" 加 `restructure` + referee 多行；新增 § "路由规则 schema"；§ "pipeline_trace 字段" 改为多 referee + restructure 记录；§ "call_record.prompt_versions" schema 改。
- `goal-achievement`: § "goal_achieved 触发来源" 从「单 referee 的 decision 字段」改为「某 referee 输出 + 路由规则命中 goal_achieved 动作」；状态机转移逻辑不变。
- `web-admin-ui`: § "Campaign 配置页" 改为多流路由界面（主对话流 + 重组流 + N 裁判 + 规则编辑）。
- `transcript`: § "pipeline_trace_records 字段" 与 data-model 同步（多 referee + restructure 命中记录）；ai_reply 事件 payload 不变。

## Impact

**受影响 sub-repo**：

- `isales-engine`: 多 referee 并行 spawn（gather）+ decider 路由规则引擎 + restructure stream 执行路径 + InterruptText 会话状态 + barge-in 残留捕获 + pipeline_trace 多 referee 写入
- `isales-common`: `role_config.kind` 加 `restructure` + referee 多行 / 路由规则数据类 + 承载 schema / pipeline_trace 模型改 / `call_record.prompt_versions` schema 改 / 新增 alembic migration
- `isales-api`: referee CRUD 去掉「恰好一个」约束 + 路由规则配置 endpoint + restructure role 配置 schema
- `isales-web`: 多裁判配置 UI（多流路由界面：主对话流 + 重组流 + N 裁判 + 路由规则编辑）+ restructure prompt 编辑入口
- `isales-worker`: 基本不动（extractor 不受影响）
- `isales-scheduler` / `isales-telephony`: 完全不动

**数据库 migration**：

- alembic 新版本：`role_config.kind` 枚举加 `restructure` + 放宽 referee 唯一性 + 路由规则承载结构 + `pipeline_trace` 多 referee/restructure 字段重构。
- **风险**：现有 campaign 的单 referee 行需在 migration 后挂上一条默认路由规则集才能保持等价行为；v1 无真实生产数据，acceptable，但 RUNBOOK 需写明「migration 后给每个 campaign seed 默认规则集」。

**依赖**：`pipeline-stream-and-referee`（active）。建议其先 archive 再实施本 change。
