# Drop `max_no_progress_seconds` — consolidate silence-timeout hangup

## Why

「线索」场景配置「沉默激活」面板下有一个 `无进展超时 (s)`（`campaign.max_no_progress_seconds`）字段，它是一个**独立的、秒级、wall-clock** 无进展计时器：从「最后一次有效用户输入」起算，超过设定秒数主动挂断，产出 `HangupCause.NO_PROGRESS_TIMEOUT`。

它与真正的「沉默超时挂断」**重复且互相误导**：

- **命名错误** —— 本质是「沉默/无进展导致的挂断」，却叫「无进展超时」，且 hint 写「可挂断」（暗示可选/不确定）。
- **与沉默激活路径重复** —— 真正的「沉默超时挂断」已由 `max_silence_activations`（最大激活次数）+ `silence_threshold_ms`（沉默阈值）+ `silence_hangup_phrase`（挂断兜底语）完整实现：达到最大激活次数后，客户再次静音达到沉默阈值 → 播挂断兜底语 → **直接挂断**（`silence_max_reached`）。`silence_hangup_phrase` 的 hint 本就逐字描述了这条路径。
- **生产中已禁用** —— `max_no_progress_seconds` 默认 NULL（关闭），现网无 campaign 设置它，删除对现网行为零影响。

违反项目「多层兜底是代码味道」原则：同一个『沉默 → 挂断』意图存在两套并行机制。本 change 删掉冗余那套，让「沉默超时挂断」只剩一条由「最大激活次数 + 沉默阈值」驱动的清晰路径。

## What changes

- **删除** `campaign.max_no_progress_seconds` 列（alembic DROP COLUMN）+ 模型字段 + Pydantic schema（common `CampaignBase`/`CampaignUpdate`、api `CampaignNestedUpdate`）。
- **删除** engine 独立无进展计时器：`realtime/no_progress_timer.py` 模块、`run_loop` 的计时器检查与 `last_progress_ms` 跟踪、`runtime_config.max_no_progress_seconds`、`settings.engine_max_no_progress_seconds` 环境变量。
- **删除** WebUI「沉默激活」面板的「无进展超时 (s)」字段（types + CAMPAIGN_DEFAULTS + `SilenceTab.vue`），并确认「沉默超限挂断」叙事在 UI 上清晰。
- **保留** `HangupCause.NO_PROGRESS_TIMEOUT` 枚举成员 —— 它另有**独立用途**：engine `run_session` 与 worker `session_runner` 的「内部异常兜底 hangup_cause」、worker `NORMAL_HANGUP_CAUSES` 分类、以及历史 `call_record` 行。删枚举会牵动错误处理与线索生命周期语义、并可能让历史行 `HangupCause(...)` 抛错，超出本次范围。详见 design.md。

## Trade-off（已与用户确认）

删除独立无进展计时器后，「客户持续发出无效噪声（ASR 一直有输入但都被忽略，从不真正沉默）」这种极端僵局**不再有秒级超时自动挂断**。由于该字段现网为 NULL（已禁用），现网行为不变；该极端场景由人工或后续机制处理。用户已确认接受。

## Impact

- Specs: `silence-activation`（改「与其他模块的优先级」超时挂断边界场景）、`call-state-machine`（删配置驱动的「长时间无进展挂断」场景 + 清理 `max_no_progress_seconds` 残留示例）、`data-model`（campaign 字段清单删列）。
- Repos: isales-common（model + schema + alembic）、isales-engine（计时器逻辑）、isales-api（schema）、isales-web（UI）。worker / scheduler 不改（仅保留枚举引用）。
- DB: alembic DROP COLUMN（down_revision `b2f3a4c5d6e7`）。无数据迁移（删的是 NULL 列）。
