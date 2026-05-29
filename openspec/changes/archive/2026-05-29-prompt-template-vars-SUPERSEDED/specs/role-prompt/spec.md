## ADDED Requirements

### Requirement: Prompt 模板变量支持

engine SHALL 支持 PG-stored prompt 内嵌 `${var}` 占位符，并 MUST 在加载 `RuntimeConfig`
阶段对 role / judge / polish 三类 prompt 的 system_prompt 做一次性替换。替换语法 MUST
使用 Python 标准库 `string.Template`（`${var}` 与 `$var` 两种形式），MUST NOT 引入额外
模板 DSL 依赖（如 jinja2 / mustache）。

#### Scenario: 支持的变量集

- **WHEN** engine 加载 `RuntimeConfig` 并对 prompt 做替换
- **THEN** 替换器 MUST 识别以下变量名：
  - `${role_prompt}` → campaign 销售角色的 system prompt（v1 取 `roles[0].system_prompt`
    的 PG 原文，**MUST NOT** 含 `OUTPUT_SCHEMA_SUFFIX`）
  - `${campaign_name}` → `Campaign.name`
  - `${lead_name}` → `Lead.name`；缺值（Lead 行不存在或 name 为 NULL）替换为空串
  - `${lead_phone}` → `request.lead.phone`
  - `${lead_custom_data}` → `Lead.custom_data` JSONB 渲染成 `k=v, k=v` 文本；空 dict 替
    换为空串

#### Scenario: 替换发生在 RuntimeConfig 加载阶段，不在 hot path

- **WHEN** engine 处理一通新通话
- **THEN** `load_runtime_config` SHALL 在构造 `RoleSpec/JudgeSpec/PolishSpec` 时把替换
  后的字面文本赋给 `.system_prompt`；`prompt_builder.build_*_messages` MUST NOT 再次执
  行变量替换；每通通话内多轮 LLM 调用 MUST 复用已替换的文本

#### Scenario: 未知变量保留字面 + WARN

- **WHEN** prompt 内含未在变量集中定义的 `${var}`（例如历史遗留 `${roleUser}` / 用户拼
  写错误 `${lead_nme}`）
- **THEN** 替换器 MUST 保留 `${var}` 字面字符串原样（使用 `safe_substitute`），MUST NOT
  raise 异常；engine SHALL 对每个未知变量打 WARN log，含 `prompt_version_id` 与变量名

#### Scenario: `${role_prompt}` 在 role 自身 prompt 内自指

- **WHEN** 某 role 的 system_prompt 内含 `${role_prompt}` 占位符
- **THEN** 替换器 MUST 将其替换为空串（避免循环引用 / 内容重复），engine SHALL 打 WARN
  log 含 `role_config_id`；其余变量（`${lead_name}` 等）替换 MUST 正常进行

#### Scenario: 替换与 OUTPUT_SCHEMA_SUFFIX 的先后顺序

- **WHEN** engine 拼装 system prompt
- **THEN** 顺序 MUST 是：① PG 原文 `prompt_version.content` → ② 变量替换 → ③ 末尾追加
  `ROLE_OUTPUT_SCHEMA_SUFFIX` / `JUDGE_OUTPUT_SCHEMA_SUFFIX` / `POLISH_OUTPUT_SCHEMA_SUFFIX`；
  SUFFIX 本身 MUST NOT 含变量占位符；`${role_prompt}` 注入的销售角色描述 MUST NOT 包含
  SUFFIX

#### Scenario: prompt_versions 快照保持指向 PG 原文

- **WHEN** 通话开始时 engine 写入 `call_record.prompt_versions`
- **THEN** 快照 MUST 仍只存 `prompt_version_id`；MUST NOT 存替换后的 final prompt 文本；
  调试回放时从 PG 取原文 + 当时的 lead/campaign 数据离线重做替换

#### Scenario: N>1 多角色时 `${role_prompt}` 取 roles[0]

- **WHEN** campaign 配置了 N>1 个 role
- **THEN** judge / polish prompt 中的 `${role_prompt}` MUST 替换为 `roles[0].system_prompt`
  （按 `role_config.id` 升序排序后的第一个）；v1 SHALL 接受此简化语义（N=1 是常态）；
  per-candidate 替换（每个 judge 调用看到对应 source role 的 prompt）留待 future change
