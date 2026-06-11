## Context

复盘 campaign 1 发现:160 通 `call_summary` 全部 `goal_achieved=false`,看板 `/analytics/goal-rate` 恒 0,lead 无一进入 `COMPLETED`。多 agent 核查(含对抗复核)定位到三层成因,且**现有 `goal-achievement` / `transcript` spec 本身是对的**——是代码漂移于 spec + campaign 配置缺口:

1. **worker 读错事件名(总闸)**:`isales_worker/llm/mock.py` 的 `_last_role_markers` 只读 `type=='bot_speech'` 的事件,但引擎写的是 `ai_reply`(transcript spec § 事件类型枚举的规范类型;枚举中**无** `bot_speech`)。`bot_speech` 是 2026-05-06 `impl-worker` 的旧事件名,`2026-06-10-fix-transcript-schema-drift` 已把契约规范成 `ai_reply`,但 worker 是那次漏改的尾巴。后果:`goal_achieved` 对**每通电话**被无条件清成 false;同文件 `_stitch_text` 同样只认 `bot_speech`,导致摘要正文丢失全部 AI 回复。该 bug 被 worker 测试 fixture(也用 `bot_speech`)掩盖——单测全过、生产全错。生产 worker 用 `MockProvider`(`ISALES_WORKER_LLM_PROVIDER` 默认 `mock`,且当前唯一实现;真 LLM 汇总属 stage 5,未做),故汇总完全靠读标记。
2. **engine `route` 动作丢 goal_type**:`pipeline/decider.py` 的 `route` 分支只取 `to` / `then_state`,不取 `goal_type`;仅 legacy `transition` 分支取。违反 `goal-achievement` spec「`goal_type` SHALL 取自命中规则 action」。后果:即便走 `route:closing`,`goal_achieved` 能置 true 但 `goal_type` 为空。
3. **campaign 1 配置缺口**:referee(`main_judge`)prompt 仅教模型输出 `HANGUP`(辱骂/投诉/拒绝/语音助手),从不输出成功类 category;且 routing_rules 里那条 `match:["SUCCESS"]` 用 `action.type=tool, tool=hangup`(`tool:hangup` 分支早 return,不进 closing route,也不记达成)。即「成功」既判不出、判出也不记。

## Goals / Non-Goals

**Goals:**
- 让「目标达成」从 referee 判定 → 路由 → transcript 标记 → worker 汇总 → `call_summary.goal_achieved/goal_type` → lead `COMPLETED` / webhook trigger,端到端真正跑通。
- 把两处「代码漂移于 spec」的 bug 修回 spec,并在 spec 补 scenario 钉死契约防再漂。
- 顺手清理 orphan 配置(`end_call`)与误导性 UI 选项(`transition(旧)` / `restructure(旧)`)。

**Non-Goals:**
- 不实现真 LLM 汇总器(stage 5);worker 仍走 marker 读取。
- 不改 wrap-up 行为/默认值,不改 `/analytics/goal-rate` 算法。
- 不做前端 per-campaign 达成率(后端端点已支持 `campaign_id`,前端接线另起 change)。
- 不回填历史 160 条 `call_summary`(见 Open Questions)。
- 不动 `isales-common` schema / 不出 alembic migration。

## Decisions

**D1 — 修 worker 对齐 `ai_reply`,而非给 engine 补写 `bot_speech`。**
transcript spec 是权威口径,`ai_reply` 是规范事件、`bot_speech` 是已废弃旧名。根因在消费方,修消费方即根治。给 engine 补写 `bot_speech` 会**新增一个冗余事件名、固化错误契约**(违反「多层兜底是问题味道」),否决。

**D2 — worker 从「倒序最近一条携带标记的 `ai_reply` 事件」读 goal 标记;独立 `goal_achieved` 里程碑事件为等价合法来源。**
保持原设计意图(标记随回复事件)。读不到标记 fail-safe 视为未达成(`goal_achieved=false`),不报错。`_stitch_text` 同步把 `ai_reply` 作为 AI 侧话语来源。备选:只读独立 `goal_achieved` 事件——否决,因普通轮的 `ai_reply` 也带 `goal_achieved=false`,统一从 `ai_reply` 读语义更一致。

**D3 — `decider.py` 的 `route` 动作对称补 `goal_type` 提取**,与 `transition` 一致(`goal_type=action.get("goal_type")`)。下游 `_select_gated_route` → `_GatedSelection` → `append_event` 透传链路已完整,decider 是唯一缺口。

**D4 — campaign 1 走 spec line 26-29 既定机制配置(非 spec 变更):**
- referee prompt 增补一段「已达成」判定语义,指示模型在「客户明确同意领取试听课 / 加微信 / 预约回访」时输出一个**裸大写 token**(如 `SUCCESS`)。注意 engine 匹配大小写敏感、取首 token 去尾标点,故 prompt MUST 要求精确单词。
- 把对应 routing rule 改为 `{referee: main_judge, match: ["SUCCESS"], action: {type: route, to: closing, then_state: WRAPPING_UP, goal_type: "intent_confirmed"}}`(goal_type 已定 `intent_confirmed`,见 Open Q1)。
- `HANGUP` 规则保持 `tool:hangup` 不变(拒绝→挂断本就不该记达成)。

**D5 — 清理:** 删 campaign `tools` 的 `end_call`(零代码引用,真塞还会过不了 tool_type 校验 fail-open);web `RoutingRulesTab.vue` + `types/campaign.ts` 动作类型下拉移除 `transition(旧)`/`restructure(旧)`。engine 保留 removal-tracked shim 仍执行存量这两类规则(0 campaign 在用,纯收口编辑入口,后端不受影响)。

**D6 — 测试 fixture 修正:** worker 测试(`test_summarize.py` / `test_callend.py` / `scripts/fake_call_end.py`)的 mock transcript 从 `bot_speech` 改 `ai_reply`,否则改完代码反被旧 fixture 测红——它们正是掩盖 bug 的来源。新增一条「`ai_reply` 输入能正确读出 goal 标记」的回归测试。

**D7 —(实装暴露,2026-06-11)route 动作扩展 goal_type,而非改用 transition。**
实装到 §3 时发现:`RoutePersonaAction`(`type:route`)schema **没有 `goal_type` 字段**,而 `AppModel` 是 `extra="forbid"`——往 route 动作写 goal_type 会让 `GET /campaigns`(CampaignRead 用 `list[RoutingRule]` 校验)500(重演 fix-transcript-schema-drift)。能携带 goal_type 的只有 legacy `TransitionAction`。三条收法(A 扩展 route schema / B 改用 transition / C route 不带标签),**用户选 A**:
- 给 `RoutePersonaAction` 加可选 `goal_type` + validator(仅 `to=closing` 合法),common 0.8.9→0.8.10。
- 好处:route 成为单一 goal 机制,真正消除「route vs transition」双轨拧巴(本 change 初衷),且先前已做的 engine decider goal_type 提取 + web 删 legacy 选项 + goal-achievement spec「对称」scenario 全部在 A 下成立。
- 代价:多一个 common schema 变更 + 重部署 common(api 必须先于配置写入上线)。
- 否决 B(双轨保留、web 删 transition 反而错)、C(丢用户选的 intent_confirmed 标签)。

## Risks / Trade-offs

- **[只修 worker/engine、不改 campaign 配置 → 达成率仍 0]** → 三处必须同 change 同批上线;config 改动依赖 D3(decider goal_type)与 D1/D2(worker)已部署。Migration Plan 锁定顺序。
- **[referee 误报达成(单角色单轮)]** → 沿用 `goal-achievement` spec 既定 trade-off:prompt 强约束判定标准 + WRAPPING_UP 收尾期用户自然纠正;不在本 change 引入投票。
- **[token 大小写/多词不匹配 → 成功规则静默不命中]** → prompt 明确要求输出精确大写裸 token;engine 取首 token 去尾标点但**不做大小写归一**,需 prompt 端保证。
- **[历史 160 条 + 3 条带 goal_achieved 事件的 transcript 不会自动回填]** → 见 Open Questions,默认不回填。
- **[`_stitch_text` 改动影响既有摘要文本格式]** → 仅把 AI 侧来源从不存在的 `bot_speech` 切到真实 `ai_reply`,是修复非回归;摘要从「只有用户话」恢复为完整对话。

## Migration Plan

无 alembic / 无 schema 变更。部署顺序:
1. **isales-engine**:部署 `decider.py` route goal_type 修复(独立可先行,不破坏现状)。
2. **isales-worker**:部署 `mock.py` / `base.py` 修复 + 测试 fixture 更新。
3. **campaign 配置**(DB/web admin):改 campaign 1 referee prompt + routing rule(`SUCCESS` → route:closing + goal_type);删 `tools.end_call`。依赖步骤 1-2 已上线。
4. **isales-web**:部署移除 legacy 动作类型选项。
5. **验收**:mac 真机/QA 拨一通走「成功」路径的电话 → 验证 transcript 出 `ai_reply{goal_achieved:true,goal_type:X}` + `goal_achieved` 事件 → worker 落 `call_summary.goal_achieved=true,goal_type=X` → lead `COMPLETED` → `/analytics/goal-rate` 非 0。
回滚:各步独立可回滚;config 改动可还原 routing rule 到 `tool:hangup`。

## Open Questions

1. ~~**campaign 1 的 `goal_type` 取值?**~~ **已定(2026-06-11):`intent_confirmed`(泛意向)**——客户表达明确意向(试听 / 加微信 / 回访任一)即算达成,标签不细分。implication:referee 成功判定准则取「客户明确正向意向(任一渠道)」这一条宽口径,prompt 较易写;代价是看板分类较粗(单一 goal_type)。
2. **单一成功 category 还是多 category(每 goal_type 一个)?** 配合 Q1 决策,定为单一 `SUCCESS` category → 单 goal_type `intent_confirmed`(MVP);未来若要细分(试听/微信/回访各一标签),按 spec line 35-39 扩展 referee 枚举 + routing_rules。
3. **是否回填历史 160 条 `call_summary`?** 默认否(v1 无真实生产数据价值,且需重放 transcript)。若要,可加一条 backfill 脚本 task。
4. **referee 成功判定的具体话术准则** 写多严?(防误报)留待 apply 时与 prompt 一起拟,可在真机验收迭代。
