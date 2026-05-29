## Context

`ai-pipeline § Requirement: 开场白不走管线` 早就声明了能力：

> Scenario: 固定模板开场白
> - WHEN Campaign 配置固定模板开场白
> - THEN engine SHALL 直接 TTS 播放该模板，不调用任何 LLM

代码层 `generate_greeting(fixed_template=...)` / `RuntimeConfig.fixed_greeting` /
`_do_greeting(fixed_template=config.fixed_greeting)` 都已就绪。

**Gap**：从 PG 到 `RuntimeConfig.fixed_greeting` 这条 plumbing 缺失。Campaign 表没
有 `greeting` 列，`load_runtime_config` 拿不到 campaign-level fixed greeting，所以
长期把 `fixed_greeting` 写死为 `None`（hack 之前的状态）或字典查找（hack 之后）。

2026-05-29 真拨号 session 用一个临时 `_FIXED_GREETINGS={1: "..."}` 字典 hack 补上
plumbing 跑了 PoC，验证了路径可工作（详见 memory `project_session_2026_05_29_handoff`）。
本 change 把这最后 25% 用正规方式（Campaign DB 列 + isales-web 编辑 UI + alembic
migration）落地，hack 删除。

## Goals / Non-Goals

**Goals:**

- Campaign 表加 `greeting` 列让 PG 存 campaign-level fixed greeting
- `load_runtime_config` 直接读 `campaign.greeting` 给 `RuntimeConfig.fixed_greeting`
- 运营在 isales-web 编辑表单存 greeting 文案即生效，无需 commit / SCP / restart
- 删除 `runtime_config._FIXED_GREETINGS` 字典 hack（技术债清理）
- 行为完全保持—— campaign id=1 的开场白仍是当前的 25 字销售文案

**Non-Goals:**

- **不**做模板变量替换（`${var}` 不解析）。跟同 session 反证 prompt-template-vars
  不必要的方向一致。业务真要个性化 lead 称呼是 future change
- **不**改 `ai-pipeline § 开场白不走管线` Requirement——既有 spec 已覆盖能力
- **不**做 greeting i18n / 多语言（当前业务全中文）
- **不**做 greeting A/B 测试 / 版本管理（真要测试就走 prompt_version 表，跟
  role/judge/polish prompt 同机制；本 change 不实施）
- **不**改 cloud-edge gRPC、call_record schema、prompt_version 表

## Decisions

### 决策 1：`greeting` 字段类型 = `Text`，nullable

**选择**：`Mapped[str | None] = mapped_column(Text, nullable=True)`

**备选**：

- A. `Text` nullable（本方案）
- B. `Text` default ''（空串作默认）
- C. `String(N)` 限长

**为何 nullable 而非空串 default**：NULL semantic 跟 "未配置 → LLM 路径" 一一映射，
强类型。空串可能意味"故意配空字符串"（发出去什么都不说），跟 NULL 语义混淆。
`load_runtime_config` 改成：

```python
fixed_greeting: str | None = campaign.greeting  # NULL → LLM path
```

`generate_greeting(fixed_template=None)` 已正确处理 None → 走 LLM。空串如果走到
`generate_greeting(fixed_template="")` 当前 `if fixed_template:` 判断会落到 LLM 分支
（空串 falsy）—— 行为虽然兼容但语义混淆。

**为何 Text 而非 VARCHAR(N)**：不限长度，给业务自由度。greeting 文案虽然短（一句一两
百字），但将来可能加 emoji / 多句，不该卡限制。Postgres Text 跟 VARCHAR 性能等同。

### 决策 2：删除 `_FIXED_GREETINGS` hack，不留兼容层

**选择**：本 change 彻底删 `runtime_config._FIXED_GREETINGS` 字典 + 改成
`fixed_greeting = campaign.greeting` 一行。

**备选**：

- A. 保留 hack 作 fallback——`campaign.greeting OR _FIXED_GREETINGS.get(campaign.id)`
- B. 彻底删（本方案）

**为何 B**：

- A 是多层 fallback，违反 `[[feedback_avoid_multilayer_fallback]]`
- 部署顺序（先 SQL UPDATE → 再 SCP 代码）保证 campaign id=1 行为不中断（详见
  Migration Plan）
- 留 hack 作 fallback 反而让下次有人来读代码以为 hack 是正式备份机制，认知负担

### 决策 3：deployment 顺序 = migration → SQL UPDATE → SCP code → restart

**选择**：

1. 先跑 alembic migration（加列，campaign id=1 的 greeting 列此时 NULL）
2. SQL `UPDATE campaign SET greeting = '<25 字销售文案>' WHERE id = 1;`
3. SCP 新 `runtime_config.py`（hack 已删，读 `campaign.greeting`）到 ECS
4. `systemctl restart isales-engine`

**关键原因**：步骤 2 / 3 顺序倒过来会让 campaign id=1 在 hack 删除后 + UPDATE 之前
那一瞬走 LLM 路径——~2069 prompt_tokens 一次 LLM 调用 + 不可控措辞，跟期望行为不一致。
按本顺序 campaign id=1 的实际跑的 greeting 内容是：

- 步骤 1 完成后：hack 字典 → "您好，我是智联招聘的小雨..."（hack 旧路径）
- 步骤 2 完成后：hack 字典还在生效（代码还没换）→ 同上
- 步骤 3 完成后：`campaign.greeting` (= "您好，我是智联招聘的小雨...") → 同上
- 步骤 4 重启 OK

整个过程 campaign id=1 的开场白文案**始终一致**。

### 决策 4：`load_runtime_config` 直接读 `campaign.greeting`，不加 cache

**选择**：

```python
fixed_greeting: str | None = campaign.greeting
```

**理由**：

- `Campaign` 在 `load_runtime_config` 已经 `await db.get(Campaign, campaign_id)` 拿到，
  直接读字段，零增量 IO
- 每次新通话 `load_runtime_config` 都会重新查 PG —— campaign 编辑界面保存 greeting
  后**下次 dial 即生效**（无需 engine 重启）
- 一次性 PG IO 已经存在（campaign row 必查），加一个字段不增加 row count

### 决策 5：isales-web 编辑入口位置 — 客户面 vs 运营面 audit 决定

**选择**：实施 task 阶段 audit `isales-web` 当前 campaign 编辑表单实施位置，把
greeting 输入框加到现有 campaign 字段编辑流程里。

**理由**：

- `web-admin-ui § Requirement: 客户面 view 清单` 提到 `/campaigns/:id` 是客户面
  CampaignDetail.vue；`Requirement: 运营面 view 收纳` 提到 `/operations/campaigns/:id/edit`
  是运营面全字段编辑
- greeting 是销售话术内容，属于业务话术编辑——既可以放客户面（campaign 详情可编辑
  字段集），也可以放运营面（campaign 全字段高级编辑）
- 不在 design 阶段拍死位置，避免跟 isales-web 当前实施假设错位。实施 task 阶段
  audit 后定位

### 决策 6：UI 控件 = textarea 3 行 + placeholder，无字符计数

**选择**：

```vue
<el-form-item label="开场白文案">
  <el-input
    type="textarea"
    :rows="3"
    v-model="form.greeting"
    placeholder="留空则由 LLM 生成开场白"
  />
</el-form-item>
```

**理由**：

- textarea 3 行刚好放典型销售开场（一两句话）
- placeholder 清晰说明留空行为 = LLM 生成
- v1 不做字符计数 / 长度限制 / 模板变量 hint —— 加复杂度但 v1 没需求
- 跟现有 `STYLE_GUIDE.md` 视觉风格保持一致（el-form-item 间距、label 长度、textarea
  圆角）

## Risks / Trade-offs

**[Risk] Alembic migration 跑失败（ECS PG 锁表 / 网络中断 / 权限）**
→ Mitigation：先 backup `pg_dump campaign` 表（按 `[[reference_state_files]]` 的 backup
SOP），再跑 migration。失败回滚走 alembic down-migration。

**[Risk] 步骤顺序错乱让 campaign id=1 那一瞬走 LLM 路径**
→ Mitigation：决策 3 锁死步骤；tasks.md 显式排序；deploy 操作单次执行不分散。

**[Risk] isales-web 编辑 greeting 时保存失败但前端 UI 显示成功**
→ Mitigation：跟所有 campaign 字段编辑共用同一保存机制，依赖 isales-api PUT 响应。
不在本 change 单独加新机制。

**[Risk] 运营改 greeting 文案为空串而非清空**
→ Mitigation：决策 1 已说明空串 falsy → 跑到 `generate_greeting(fixed_template="")` 时
当前 `if fixed_template:` 落到 LLM 分支（兼容行为）；但语义模糊。isales-web 表单
保存时 SHOULD 把空字符串 normalize 为 NULL 送 PG（实施 task 阶段处理）。

**[Risk] 多 campaign 配置 greeting 后 PG 表行数大幅增加（不可能，但提一下）**
→ Mitigation：Text 字段加列对 row 大小影响极小（TOAST 处理长文本）；campaign 行数
本身就是 O(campaign_count)，加列不改变量级。不构成 risk。

**[Risk] greeting 文案含特殊字符（HTML / SQL injection）**
→ Mitigation：PG `Text` 类型自动处理转义；TTS provider 拿到 Python str 不做 HTML
渲染（只发音字符）。无注入面。

## Migration Plan

详见 proposal.md `Impact` 部分。简略：

1. `alembic upgrade head` （加 `greeting` 列）
2. `UPDATE campaign SET greeting = '您好，我是智联招聘的小雨，请问您现在方便接电话吗？' WHERE id = 1;`
3. SCP 新 `runtime_config.py`（hack 删除）→ ECS
4. `systemctl restart isales-engine`
5. mac dev DingRTC 真拨号验证 TTS first_byte text_len=25 仍跟当前一致

**Rollback**：

- 数据层：`alembic downgrade -1` 删 `greeting` 列
- 引擎层：SCP 回旧版 `runtime_config.py`（含 hack 字典）→ restart
- ECS engine 上的 working tree dirty 状态本来就长期不清，rollback 完只是回到 2026-05-29
  当时的 hack 状态

## Open Questions

1. **isales-api campaign POST/PUT 接口的 schema 严格度**：实施 task 阶段 audit 决定要
   不要改 isales-api。如果 schema 用 `model_dump(exclude_unset=True)` 透传所有字段那
   不需要改；如果显式列字段那要补 `greeting`。

2. **isales-web 编辑入口具体放在哪个 view**（客户面 CampaignDetail.vue vs 运营面
   `/operations/campaigns/:id/edit`）——决策 5 推迟到实施 task 阶段 audit。

两个 question 都不阻塞本 change archive；实施时澄清即可。
