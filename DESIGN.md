# iSales 系统设计

> AI 外呼销售系统。消费线索 → LLM 生成话术 → TTS 合成 → ASR 解析 → 多轮对话 → 目标达成时回调外部 API。
>
> 本文档汇总 2026-04-27 ~ 04-28 设计讨论的最终结论，是后续所有实施工作的依据。

---

## 1. 架构总览（7 仓库）

**v1 部署模型：单主机全部同部**（engine + telephony + scheduler + worker + USB GSM modem 都在一台服务器，匹配 ≤8 路并发目标）。

```
┌────────────────────────────────────────────────────────────────────┐
│                          isales-web (Vue 3)                         │
└──────────────────────────────────┬─────────────────────────────────┘
                                   │ HTTP / WebSocket
                                   ▼
┌────────────────────────────────────────────────────────────────────┐
│                  isales-api (管理 API + WS 代理)                    │
│   Campaign / Lead / Role / Voice / Call / Analytics / Callback     │
└──────┬──────────────┬──────────────────┬──────────────┬────────────┘
       │              │                  │              │
       │       Redis Pub/Sub      Redis Queue           │ HTTP
       ▼              ▼                  ▼              ▼
┌────────────┐ ┌──────────────────┐ ┌────────────────┐ ┌──────────────────┐
│ scheduler  │ │     engine       │ │    worker      │ │ telephony        │
│ 调度服务    │ │  通话引擎(核心)   │ │  异步后处理     │ │ (api + modem)    │
│            │ │                  │ │                │ │                  │
│ 线索分发    │ │ 状态机            │ │ 摘要生成        │ │ ┌──────────────┐ │
│ 时间窗口    │ │ AI 管线 PK        │ │ 字段提取        │ │ │ telephony-api│ │
│ 重试/跟进   │ │ 打断/沉默/垫词    │ │ Webhook 回调    │ │ │ device/SIM   │ │
│ 历史摘要打包 │ │ ASR/TTS/LLM     │ │ 数据聚合        │ │ │ CRUD + 选 API│ │
└──────┬─────┘ └────────┬─────────┘ └────────────────┘ │ └──────┬───────┘ │
       │                │                              │        │ 共享 DB │
       │                │ 本地 IPC (Unix socket)        │ ┌──────▼───────┐ │
       │                └──────────────────────────────►│ │ modem-       │ │
       │                                                │ │ controller   │ │
       │                                                │ │              │ │
       │                                                │ │ udev / AT 命令│ │
       │                                                │ │ PCM 音频管道  │ │
       │                                                │ └──────┬───────┘ │
       │                                                └────────│─────────┘
       │                                                         │
       │                                                         ▼
       │                                                 ┌──────────────┐
       │                                                 │ USB GSM      │
       │                                                 │ Modem × N    │
       │                                                 │ (每台 1 SIM) │
       │                                                 └──────────────┘
       │
       └─→ 拨号前调 telephony-api /select-device

         ┌──────────────────────────────────┐
         │  isales-common (pip 共享库)       │
         │  Models / Schemas / Provider ABC │
         │  Alembic 迁移 / Utils            │
         └──────────────────────────────────┘
              ▲ 被 6 个服务共同依赖
```

| 仓库 | 职责 | 规模 |
|------|------|------|
| **isales-common** | SQLAlchemy 模型、Pydantic Schemas、Provider ABC（ASR/TTS/LLM）、Alembic 迁移、utils | 小 |
| **isales-api** | 管理后台 CRUD（Campaign/Lead/Role/Voice/Analytics/Callback），WS 代理给前端推送实时通话状态 | 中 |
| **isales-engine** | 实时通话引擎：状态机、AI 三层管线、打断/沉默/垫词、ASR/TTS/LLM Provider 实现、调 modem-controller 拨号与音频流 | 大 |
| **isales-scheduler** | 线索分发、可通话时间窗口、重试与跟进策略、拨打前打包历史摘要 | 小 |
| **isales-worker** | 通话结束后的摘要、字段提取、Webhook 回调、聚合统计 | 中 |
| **isales-telephony** | **包含两个独立进程：** ① `telephony-api`（HTTP，device/SIM 管理 + 选 device） ② `modem-controller`（守护进程，AT 命令 + PCM 音频 + udev 监听） | 中 |
| **isales-web** | Vue 3 前端（任务/线索/角色/音色/设备/数据看板/通话监控） | 中 |

---

## 2. AI 三层管线（核心）

每一轮对话生成回复都走 **3 层 LLM**：

```
用户语音 (ASR)
    │
    ▼
┌────────────────────────────────────────────────────┐
│  Layer 1: 角色 LLM（N 个并行）                       │
│  Campaign 配置 N 个角色，各自独立 prompt 和 model    │
│  并发产出 N 份候选回复                               │
└──────────────┬─────────────────────────────────────┘
               │ N 份候选 → 同时启动 Layer 2
               │ 同时启动垫词播放（覆盖整个管线延迟）
               ▼
┌────────────────────────────────────────────────────┐
│  Layer 2: 裁判 LLM（N×M 个并行）                     │
│  Campaign 配置 M 个裁判，每个候选被 M 个裁判审查      │
│  任一裁判不通过 → 该候选被淘汰                       │
└──────────────┬─────────────────────────────────────┘
               │ 通过的候选集
               ▼
┌────────────────────────────────────────────────────┐
│  Layer 3: 润色 LLM（1 个）                          │
│  从通过的候选中选优 + 拟人化改写                      │
│  失败时由 orchestrator 降级：取通过候选的第一个       │
└──────────────┬─────────────────────────────────────┘
               │
               ▼
            TTS → 播放
```

**结构化输出（目标达成机制的载体）：**
- 角色 LLM 强制 **JSON Mode** 输出：`{reply, goal_achieved, goal_type, extracted}`
- 裁判 LLM 只审 `reply` 字段，标记字段透传不审
- 润色 LLM 只改写 `reply` 做拟人化；标记字段从被选中候选**直接继承**（不做投票合并）
- 详见 §5「目标达成与收尾」

**特殊情况：**
- **全部候选被裁判淘汰** → 用 Campaign 的默认回复（多条随机抽 1，无场景区分）
- **润色失败** → orchestrator 选"所有裁判都通过的第一个候选"作为兜底
- **开场白** → 不走管线（固定模板或单 LLM 直出 TTS），但作为后续轮次的对话历史

---

## 3. 通话状态机（engine 核心）

```
            INIT
              │ 拨号成功
              ▼
        ┌─ GREETING ─┐  开场白播放（不过裁判/润色）
        │            │
        ▼            ▼
   LISTENING ◄── SPEAKING ──► INTERRUPTED
        │           ▲              │
        │           │              │ 用户说话被判定为打断
        │           │              ▼
        │      FILLER ──────► PROCESSING
        │      (垫词)         (AI 管线)
        │                          │
        │                          ├─ goal_achieved=false → 回 SPEAKING
        │                          │
        │                          └─ goal_achieved=true ─► WRAPPING_UP
        │ 沉默超阈值                                            │ 简化管线
        ▼                                                     │ 收尾 N 轮 / T 秒
   ACTIVATING (沉默激活，限次数)                                  │ 谁先到先挂
        │                                                     │
        │ 关键词 / 意图 / LLM 触发                                │
        ▼                                                     │
   TRANSFERRING ──► 播衔接话术 → 标记派发 → 主动挂断 ─────► END
                                                              ▲
        长时间无有效输入 / 用户挂机 ──────────────────────────────┘

       END ──► 进 worker 队列做后处理
```

**关键转换规则：**
- `SPEAKING → INTERRUPTED`：用户说话**且**（不在白名单**且**时长 ≥ 阈值）
- `FILLER` 期间 ASR 持续工作；若用户在垫词中开始有效说话，停止垫词，丢弃当前管线，作为新一轮处理
- 连续 `INTERRUPTED` 超阈值（如 3 次）→ 切换简短回复策略或主动 "您请说" 进入纯听模式
- `ACTIVATING` 次数受 Campaign 配置限制（如全程最多 2 次）
- `PROCESSING` 输出 `goal_achieved=true` → 进入 **WRAPPING_UP**（收尾模式，详见 §5）
- `WRAPPING_UP` 在收尾轮数 / 收尾时长任一耗尽时 → END
- `END` 触发条件：用户挂断 / 收尾结束 / 转人工标记派发完成 / 长时间无有效输入

---

## 4. 关键业务规则

| # | 规则 | 说明 |
|---|------|------|
| 1 | 音色绑定 **Campaign 级** | 整通电话音色统一，不随 PK 选优变化 |
| 2 | 垫词绑定 **Campaign 级** | 垫词集合按策略选择（顺序/随机），多角色 PK 期间共用 |
| 3 | 垫词不中断回复 | 垫词播完才接 TTS 回复；除非用户在垫词期间打断 |
| 4 | 裁判失败 → 默认回复兜底 | 不重试 LLM，直接用 Campaign 的默认回复（多条随机） |
| 5 | 打断判定 | 白名单命中 **或** 时长 < 阈值 → 任一满足即不算打断 |
| 6 | 开场白不过裁判和润色 | 内容可预期，无审查必要；但记入对话历史 |
| 7 | 跟进历史摘要由 scheduler 打包 | engine 不直接查 DB，scheduler 在拨号消息中带上摘要 |
| 8 | 全局并发 = Redis 原子计数器 | INCR/DECR 跨 engine 实例生效 |
| 9 | 沉默激活有次数上限 | Campaign 配置，超过则进入挂断流程 |
| 10 | 转人工有 4 种触发 | 关键词、意图分类、轮次阈值、独立 LLM 判定 |
| 11 | 目标达成靠角色 LLM 结构化标记 | JSON Mode 输出 `goal_achieved/goal_type/extracted`，详见 §5 |
| 12 | 目标达成后进入收尾模式 | 简化管线再聊几句主动挂断（双计数器：轮数 + 时长，谁先到先挂） |
| 13 | 长时间无进展自动挂断 | 用户一直说但都被判定为"非打断/无效内容"超过 `campaign.max_no_progress_seconds` 时主动挂断（区别于沉默激活） |

---

## 5. 目标达成与收尾

### 判定时机：实时，不离线

目标达成判定**不放在通话结束后**，而是每一轮回复内由角色 LLM 自己完成。理由：通话中能立刻进入收尾、节省时长；离线判定无法支持"达成后主动挂断"。

### 角色 LLM 输出契约

每个角色 LLM 强制 **JSON Mode** 输出如下结构：

```json
{
  "reply": "好的，那就周三下午 3 点见，地址等下短信发您。",
  "goal_achieved": true,
  "goal_type": "appointment",
  "extracted": {
    "appointment_time": "2026-05-06T15:00:00",
    "location": "短信通知"
  }
}
```

**字段说明：**

| 字段 | 说明 |
|---|---|
| `reply` | 要播给用户的话术，**唯一**进入裁判和润色的内容 |
| `goal_achieved` | 本轮对话是否使目标达成（角色根据 prompt 中的目标定义判定） |
| `goal_type` | 达成的目标类型（如 `appointment` / `wechat_added` / `intent_confirmed`），由角色 prompt 自定义 |
| `extracted` | 从对话中提取的结构化字段。可提取的字段类型由 `campaign.extraction_fields` 配置，但具体抽取与回复在角色 LLM 同一轮完成 |

**目标定义在 prompt 里：** Campaign 不固化目标 schema，目标定义、判定准则、可提取字段名全部写在角色 prompt 中。这样支持多目标 / 部分达成 / 自定义类型，无需 schema 变更。

### 三层管线对结构化标记的处理

| 层 | 输入 | 处理 | 输出 |
|---|---|---|---|
| 角色 LLM (×N) | 对话上下文 | 强制 JSON 输出 | N 份 `{reply, goal_achieved, goal_type, extracted}` |
| 裁判 LLM (×N×M) | 仅 `reply` 字段 | 合规审查 | 通过 / 不通过 |
| 润色 LLM | 通过的候选集合 | 选优 + 拟人化改写 `reply` | 1 份最终结果，**标记字段从被选中候选直接继承** |

> 单角色误报目标达成的风险由"角色 prompt 设计 + 收尾期间用户的反应"两层兜底，不在润色层做投票合并（决策见 §17）。

### 收尾模式（WRAPPING_UP 状态）

当润色返回 `goal_achieved=true` 时，engine 进入 **WRAPPING_UP** 状态：

1. 当前轮回复正常 TTS 播放
2. 切换 prompt：通知角色「目标已达成，进入收尾，请简短确认/告别」
3. 后续轮次走**简化管线**：单角色 LLM 直出 + 润色拟人化，**不 PK、不裁判**
4. 双计数器**谁先到谁挂断**：
   - 轮数：`campaign.wrap_up_max_rounds`（默认 2）
   - 时长：`campaign.wrap_up_max_seconds`（默认 15）
5. 计数耗尽后 engine 主动播放挂断话术（`campaign.wrap_up_closing_phrases` 中随机一条，如「那我们就这样，回头联系」）→ END

**收尾期间的特殊情况：**

| 情况 | 处理 |
|---|---|
| 用户提出新问题 | 继续走简化管线回应，不退回主管线 |
| 用户主动挂断 | 直接 END |
| 用户明确反悔 | 仍按收尾流程结束，不退回主管线（避免反复） |
| 转人工触发 | 收尾让位，进 TRANSFERRING |

### 通话结束后的责任划分

- **engine** 已在通话中实时完成目标判定，结果带在最后一轮 transcript 中
- **worker** 的 `summarize_call` **不再做目标判定**，只做：
  - 摘要生成
  - 把最后一轮的 `goal_achieved` / `goal_type` / `extracted` 写入 `call_summary`
- **worker** 的 `process_callbacks` 匹配 `callback_config.trigger`：
  ```
  trigger 表达式可引用 goal_achieved 和 extracted.* 字段
  例：goal_achieved == true && goal_type == "appointment"
  ```

---

## 6. 角色 Prompt 设计规范

iSales 的 prompt 结构是 AI 三层管线的输入合约。本章定义 prompt 的组装方式、各类 LLM 的 prompt 来源、版本管理。

### 6.1 总体原则

- **Prompt 内容由 Campaign 完全控制**：系统不提供"统一裁判规则"或"统一润色 prompt"，所有 LLM 的 prompt 都在 Campaign 级配置
- **系统只提供工具与模板**：v1 阶段先支持自定义 prompt 跑通工程链路；后续在 isales-web 增加可视化模板填空作为「双模式」中的简单模式
- **JSON 输出由 Provider 原生 JSON Mode 强制，prompt 文本约束兜底**

### 6.2 Prompt 组装结构

每次调用角色 LLM，engine 按以下结构组装：

```
┌─────────────────────────────────────────────────┐
│ system message                                   │
│   = 角色身份 + 目标定义 + JSON 输出 schema       │
│     + 可选追加：收尾指令（仅 WRAPPING_UP 期间）   │
├─────────────────────────────────────────────────┤
│ user message（单条，拼接）                        │
│   ┌───────────────────────────────────────┐    │
│   │ 【上次通话纪要】（仅跟进时存在）         │    │
│   │   ...                                   │    │
│   ├───────────────────────────────────────┤    │
│   │ 【线索信息】name, phone, custom_data... │    │
│   ├───────────────────────────────────────┤    │
│   │ 【对话】                                 │    │
│   │   AI: 开场白...                          │    │
│   │   用户: 你好                             │    │
│   │   AI: ...                                │    │
│   │   用户: 周三可以吗                       │    │
│   │   AI:                                    │    │
│   └───────────────────────────────────────┘    │
└─────────────────────────────────────────────────┘
```

**对话格式说明：**
- **不使用标准 chat 接口的 multi-turn messages**，整通对话拼成一段文本放入单条 user message
- AI 和用户的发言用统一前缀（`AI:` / `用户:`）区分
- 最后一行以 `AI:` 结尾，让模型知道接下来轮到自己说话
- 跟进时上次通话摘要作为独立段，放在 user message 最顶部

**对话过长策略：** v1 **不做截断或摘要**，依赖 LLM 长上下文能力。每个 Provider 接入时记录 token 用量并接入监控告警，避免成本失控。

### 6.3 System Prompt 内容规范

System prompt 由 Campaign 编写，建议遵循以下结构（isales-web 模板会复用）：

```
你是 {{角色身份描述}}。

【目标】
{{自由文本描述本次外呼的核心目标}}

【判定为达成的具体标准】
- {{标准 1}}
- {{标准 2}}
- ...

【可提取字段】
{{字段名}}：{{含义和格式要求}}
...

【输出格式】
你必须严格按照以下 JSON 格式输出（不要添加任何解释性文字）：
{
  "reply": "<要播给用户的话术>",
  "goal_achieved": <true 或 false>,
  "goal_type": "<达成的目标类型，未达成时为空字符串>",
  "extracted": { <本轮新提取到的结构化字段> }
}

【话术规范】
- {{风格要求}}
- {{合规要求}}
- ...
```

**收尾期间的追加：** WRAPPING_UP 状态下，engine 在原 system prompt **末尾追加**以下段落，原内容不变：

```
---
【当前状态：收尾对话】
目标已达成。请简短确认或告别后结束对话，不要再尝试推进新议题。
```

### 6.4 各类 LLM 的 Prompt 来源

| LLM | Prompt 来源 | 数量 |
|---|---|---|
| **角色 LLM** | Campaign 完全自定义；多个角色 prompt **完全独立**（不共享 base） | N 个，N 由 Campaign 配置 |
| **裁判 LLM** | Campaign 完全自定义；系统不提供基础规则 | M 个，M 由 Campaign 配置 |
| **润色 LLM** | Campaign 完全自定义 | 1 个 |
| **沉默激活 / 收尾挂断话术 / 摘要 / 字段提取** | 见各自章节 | 各 1 个 |

> **设计权衡：** 系统不强加 prompt，把全部控制权交给 Campaign 创建者。代价是新建 Campaign 工作量较大；收益是不同业务场景的灵活性最大化。isales-web 上提供模板库和示例 Campaign 减轻负担。

### 6.5 JSON Mode 强制策略

**两步保护：**

1. **Provider 原生 JSON Mode**（首选）
   - OpenAI: `response_format={"type": "json_object"}`
   - Claude: tool use 或 prompt 强约束
   - 阿里通义 / 火山豆包 / 智谱：各自原生 JSON Mode
   - Provider ABC 中暴露 `supports_json_mode: bool` 标志

2. **文本约束兜底**（Provider 不支持时启用）
   - System prompt 末尾贴 schema 描述
   - 后处理：尝试 `json.loads` → 失败则正则提取 `{...}` 段重试 → 再失败则**降级**：整段文本作为 `reply`，其余字段全部置空

**解析失败的处理：**
- 单个角色解析失败 → 该候选直接淘汰（等同被裁判否决）
- 全部 N 个角色都解析失败 → 走 Campaign 默认回复

### 6.6 版本管理

**Schema 设计：**

| 表 | 关键字段 |
|---|---|
| `prompt_version` | id, scope_type(`role`/`judge`/`polish`), scope_id, content, created_at, created_by, is_active |
| `role_config` | 增加 `current_prompt_version_id` 字段（指向当前生效版本） |
| `call_record` | 增加 `prompt_versions(JSONB)` 字段，记录本次通话使用的全部 prompt_version_id 集合 |

**行为：**
- 编辑 prompt → 自动建新版本，旧版本保留只读
- 启用某版本 → 更新对应 `role_config.current_prompt_version_id`
- 通话开始时 engine 把当时各 LLM 的 prompt_version_id 一次性写入 `call_record.prompt_versions`：

```json
{
  "role_llms": [{"role_config_id": 1, "prompt_version_id": 5}, ...],
  "judge_llms": [{"role_config_id": 7, "prompt_version_id": 12}, ...],
  "polish_llm": {"role_config_id": 9, "prompt_version_id": 3},
  "wrap_up_appended": true
}
```

- 调试 / 回放时通过 prompt_version_id 取到当时的原文，可精准复现

---

## 7. 打断判定

打断判定决定 SPEAKING 状态下用户说话是否触发中断 AI 当前回复。误判为打断会让 AI 反应过度（被"嗯嗯"中断），漏判则用户感觉被 AI 强行覆盖。

### 7.1 ASR 接入策略

- **Provider ABC 抽象**：`isales-common.providers.asr` 定义统一接口（流式音频输入 + 中间/终态文本输出 + VAD 事件），具体 provider 可插拔
- **v1 默认实现**：火山引擎（豆包）实时语音识别
- **VAD 来源**：依赖 ASR Provider 自带的 `speech_start` / `speech_end` 事件，不引入独立 VAD 模型
- **关键依赖**：Provider 必须支持
  - 流式中间结果（partial result）持续推送
  - VAD 事件带时间戳
- **不依赖**（v1 范围内）：词级时间戳、终态结果做打断判定

### 7.2 打断判定的输入与时机

```
用户开始说话
   │
   ▼
ASR speech_start 事件 ──→ interruption_detector 启动计时（t_start）
   │
   ▼
ASR 推送 partial result #1 ──→ 立即判定一次（白名单 OR 时长）
   │
   ▼
ASR 推送 partial result #2 ──→ 再判定一次
   │
   ...
   │
   ├─ 中途任一次判定为"非打断" → 继续 SPEAKING（TTS 不停）
   │
   ├─ 中途某次判定为"打断"     → 立刻停 TTS，进 INTERRUPTED → PROCESSING
   │                              （用 ASR 终态结果作为用户本轮输入）
   │
   └─ 用户说完 (speech_end)   → 若全程都是"非打断"则丢弃这段输入
```

**判定节奏：** 每次 ASR 推送中间结果都立即判定，**响应最快**。

**判定结果"打断"的不可撤销性：**
- 一旦判定打断 → 立刻停 TTS → 进 INTERRUPTED → PROCESSING
- 不再回退或恢复 TTS（即使后续中间结果显示其实是嗯嗯）
- 代价：可能误打断（用户先嗯嗯再说"你接着说"会被截）
- 收益：实现简单、状态机清晰、延迟低

### 7.3 判定逻辑

```python
duration_ms = t_now - t_start
text = latest_partial_result

# 双条件，任一满足即"非打断"
is_in_whitelist = text in campaign.interruption_whitelist   # 整段完全匹配
is_too_short    = duration_ms < campaign.interruption_min_duration_ms

if is_in_whitelist or is_too_short:
    return "non_interrupt"  # 继续 SPEAKING
else:
    return "interrupt"       # 立刻停 TTS
```

**白名单匹配语义：整段完全匹配。**
- 白名单示例：`["嗯", "嗯嗯", "好", "好的", "哦", "哦哦", "对", "是的"]`
- 用户说「好的」 → 命中 → 不打断
- 用户说「好的我看一下」 → 不命中 → 走时长判定（超阈值则打断）

### 7.4 连续打断保护

当连续 `INTERRUPTED → PROCESSING → SPEAKING → INTERRUPTED` 循环超过 `campaign.max_continuous_interruptions`（默认 3）时，触发保护策略：

| 策略 | 行为 |
|---|---|
| `short_reply`（默认） | 切换简短回复模式：角色 LLM prompt 临时追加「请用一句话回应」，避免长 TTS 再被打断 |
| `listen_only` | AI 主动说一句「您请说」，进入纯听模式，等用户说完整段（VAD speech_end）再回应 |

策略由 `campaign.continuous_interruption_strategy` 配置。计数器在用户完成一轮完整对话（无打断的 SPEAKING）后清零。

### 7.5 配置字段（加到 campaign 表）

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `interruption_whitelist` | JSONB array | `["嗯","嗯嗯","好","好的","哦","哦哦","对","是的"]` | 白名单短语 |
| `interruption_min_duration_ms` | int | 800 | 时长阈值，低于此值视为非打断 |
| `max_continuous_interruptions` | int | 3 | 触发保护策略前允许的连续打断次数 |
| `continuous_interruption_strategy` | enum | `short_reply` | `short_reply` / `listen_only` |

**配置粒度：Campaign 级**。不做全局默认覆盖、不做 Role 级独立配置。

### 7.6 与其他状态的交互

- **FILLER 期间被打断**：垫词播放时 ASR 持续工作，命中"打断"则停垫词、丢弃当前 PROCESSING 中的管线、把用户输入作为新一轮处理（见 §3 状态机规则）
- **WRAPPING_UP 期间被打断**：判定逻辑不变，但 PROCESSING 走简化管线（单角色 LLM + 润色，不 PK 不裁判）

---

## 8. 垫词机制

垫词在 AI 管线处理期间播放，覆盖 LLM/TTS 延迟。**Campaign 级配置**，整通电话音色统一。

### 8.1 触发场景

| 场景 | 是否播垫词 |
|---|---|
| 常规对话 PROCESSING | ✅ |
| 开场白后第 1 轮 PROCESSING | ❌ |
| WRAPPING_UP 期间 PROCESSING（简化管线） | ❌ |
| 转人工 / 沉默激活 | ❌ |

### 8.2 启动时机

```
用户说完（VAD speech_end）
   │
   ├──→ 启动 AI 三层管线（异步）
   └──→ 同时启动垫词播放（不等管线返回）
        │
        ├─ 垫词播放期间，管线产出 reply（TTS 流准备好）
        │     → 等垫词播完，立即接 reply 的 TTS
        │
        └─ 垫词播放期间，被用户打断
              → 停垫词、丢弃 PROCESSING、新一轮处理
```

**快响应场景：** 即使管线 < 500ms 返回，仍播垫词再接 reply，保证节奏一致。

### 8.3 垫词选择策略

**多 filler_set（集合）的选择 = 轮询：**
- Campaign 关联多个 filler_set，按 `sort_order` 依次使用，到末尾后循环
- 每通电话开始时，从 `sort_order` 最小的 filler_set 起步
- 多个 filler_set 之间**不区分语义类型**（无 thinking/confirming 之分），就是普通分组

**集合内的多句垫词 = 随机不重复：**
- 每通电话维护已用短语集合（call_session 内存态，挂断即清）
- 每次从集合内未使用的短语中随机抽 1 句
- 集内全部用完 → 清空记录，下一轮可重抽

**示例：** Campaign 配 3 个 filler_set，每个 5 句：
- 第 1 轮 → set#1 随机 1 句
- 第 2 轮 → set#2 随机 1 句
- 第 3 轮 → set#3 随机 1 句
- 第 4 轮 → set#1 再随机 1 句（不与第 1 轮重复）

### 8.4 音频来源：预生成 + 动态补充

- 用户在 isales-web 录入垫词文本（如「让我看一下」）
- 系统**预先**用 Campaign 配置的音色做 TTS 生成音频，存到 OSS
- 触发预生成的事件：
  - Campaign 新增 / 编辑 filler_phrase
  - Campaign 音色切换 → 该 Campaign 全量 filler_phrase 重新生成
- 预生成在 isales-worker 的后台任务中执行（详见 §9）

**为什么不每次实时 TTS：**
- 垫词目的本就是覆盖 TTS 延迟，再加一次 TTS 失去意义
- 同样音频预生成一次重复用，节省成本

### 8.5 失败兜底

| 失败场景 | 处理 |
|---|---|
| 预生成未完成（新建 Campaign 立即拨打） | 跳过垫词，直接等 reply |
| 音频文件下载失败 | 跳过垫词，直接等 reply |
| 全部 filler_set 都没有可用音频 | 跳过垫词，直接等 reply |

**允许"无声延迟"，不引入"万能兜底垫词"。**

### 8.6 数据模型变更

```
campaign
  └─ (移除 filler_set_id 字段；改由 filler_set.campaign_id 反向关联，1:n)

filler_set                    ← 简化：移除 strategy 字段（策略固定）
  ├─ id
  ├─ campaign_id
  ├─ name
  ├─ sort_order               ← 轮询顺序
  └─ created_at / updated_at

filler_phrase                 ← 新表
  ├─ id
  ├─ filler_set_id
  ├─ phrase                   ← 文本
  ├─ audio_url                ← OSS 路径（可空，待预生成）
  ├─ generation_status        ← pending / ready / failed
  └─ created_at / updated_at
```

### 8.7 与其他模块的交互

- **被打断的处理**：详见 §7.6
- **音色切换的级联**：触发 worker `regenerate_filler_audio` 任务
- **Worker 任务清单新增**：`regenerate_filler_audio`（具体实现见 IMPLEMENTATION_PLAN.md）

---

## 9. 转人工（v1：标记 + 通知，不做实时桥接）

### 9.1 v1 范围说明

v1 选择自研 USB GSM modem 方案，**不引入 SIP/PBX 设施**，因此**不做实时话路桥接**。转人工衰减为：

> AI 在通话中识别需要人工介入 → AI 礼貌告知用户「稍后专员会主动联系您」 → AI 主动结束通话 → 系统派发待回拨任务给坐席 → 坐席从 Web UI 主动回拨用户

实时 SIP 桥接 / GSM 呼叫转接 (AT+CHLD) / 自研 SIP 软话机 三种实时桥接方案列入 §18 v2 计划。

### 9.2 触发机制：4 种独立开关，OR 关系

每种触发独立启用 / 禁用 / 参数配置。多触发同时启用时为 **OR**：任一命中即触发。

| 触发类型 | 配置字段 | 工作原理 / 时机 |
|---|---|---|
| **关键词** | `transfer_keyword_enabled` + `transfer_keywords(JSONB)` | ASR 终态结果包含匹配关键词；每次 speech_end 后判定 |
| **意图分类** | `transfer_intent_enabled` + `transfer_intent_threshold` | 独立的轻量意图分类器（每轮 PROCESSING 并行跑）输出"转人工意图"概率超阈值 |
| **轮次阈值** | `transfer_round_enabled` + `transfer_round_threshold` | 对话超 N 轮仍未达成目标；每次进入 PROCESSING 时检查 |
| **独立 LLM** | `transfer_llm_enabled` + `transfer_llm_prompt_version_id` | 每轮 PROCESSING 并行调用一个独立 LLM，输出是否需要转 |

### 9.3 v1 转人工流程

```
触发条件命中
   │
   ▼
state_machine: → TRANSFERRING
   │
   ▼
engine 播放衔接话术（campaign.transfer_phrases 随机 1 条）
   │
   ▼
等 TTS 播完
   │
   ▼
engine 主动挂断
   │
   ▼
call_record.transfer_status = "marked_for_handoff"
call_record.transfer_reason = "<触发类型>"
   │
   ▼
worker 处理：
  - 创建 handoff_task 记录（待坐席领取）
  - 触发 callback_config 通知 CRM（如配置）
```

**没有"无坐席兜底"分支**：因为 v1 不做实时桥接，所有触发都走"标记+通知"路径，没有"立刻接通"的需求。

### 9.4 坐席侧工作流

坐席登录 isales-web，看到「待回拨」任务列表。每条任务包含：
- 用户线索基础信息（姓名 / 来源 / 自定义字段）
- 转接原因（哪种触发命中、关键词匹配片段或 LLM 判定理由）
- 完整 transcript（含开场白、用户回复、AI 回复、提取字段）
- 触发时刻、距今时长

坐席决定时机后手动外呼用户（v1 通过其他业务电话系统）。坐席处理完毕后在 Web UI 标记任务完成。

### 9.5 衔接话术

| 字段 | 类型 | 说明 |
|---|---|---|
| `transfer_phrases` | JSONB array | N 条衔接话术，随机抽 1（v1 用于"礼貌告知后挂断"） |

**示例：**
```json
{
  "transfer_phrases": [
    "好的，我请我们的专业顾问稍后主动联系您",
    "您稍等，专员会很快电话联系您"
  ]
}
```

> v1 不需要 `transfer_no_agent_phrase`（没有"无坐席"的失败路径，所有触发都直接派任务）。

### 9.6 数据模型变更

| 表 | 变更 |
|---|---|
| `agent` | 简化：保留 name / login_user / status (online/offline) / created_at —— v1 不需要 sip_number |
| `handoff_task` | **新表**：call_record_id, agent_id (nullable, 待领取时为空), trigger_type, trigger_detail, status (pending/in_progress/completed/dropped), created_at, picked_up_at, completed_at |

### 9.7 与状态机的交互

- `TRANSFERRING` 期间不走 AI 管线，但 ASR 可继续流式（用于补录最后一条 transcript）
- 衔接 TTS 播完 → 进 `END`（reason: `marked_for_handoff`）
- 不存在"转接成功 / 失败"分支

---

## 10. 沉默激活

用户长时间不说话时 AI 主动激活，避免冷场或线路异常导致的"哑通话"。

### 10.1 触发与上限流程

```
LISTENING 状态
   │
   │ 计时起点 = max(用户最后一次 speech_end, AI 上一轮 TTS 播完时刻)
   ▼
计时 > campaign.silence_threshold_ms（默认 5000）？
   │
   ├─ 否 → 继续 LISTENING
   │
   └─ 是 → 已激活次数 < campaign.max_silence_activations（默认 2）？
            │
            ├─ 是 → 进 ACTIVATING：播第 i 条话术（i = 已激活次数）
            │       │
            │       │ TTS 播完
            │       ▼
            │   重新启动计时器（以 TTS 播完为新起点） → 回 LISTENING
            │
            └─ 否 → 播 campaign.silence_hangup_phrase → END
```

**关键：每次激活 TTS 播完后重新计时**，不累加用户原始沉默时长。

### 10.2 话术来源与选择策略

**来源：Campaign 级配置话术库（`campaign.silence_phrases`，JSONB array）**

**选择策略：顺序使用** —— 第 1 次激活用 `silence_phrases[0]`，第 2 次用 `silence_phrases[1]`...

**话术数与上限不一致时（独立配置，允许不匹配）：**

| 情况 | 处理 |
|---|---|
| 话术数 = 上限 | 一一对应 |
| 话术数 < 上限 | 用完后**最后一条复用**直至达到上限 |
| 话术数 > 上限 | 只用前 `max_silence_activations` 条，剩余不触发 |

### 10.3 上限达到后的行为

播放 `campaign.silence_hangup_phrase`（如「那今天就先这样，稍后联系，再见」）→ 等 TTS 播完 → 主动挂断 → 进 END（reason: `silence_max_reached`）。

### 10.4 transcript 与角色 LLM 的关系

- 激活话术**写入 transcript**（标记 `type: "silence_activation"`）
- 激活话术**不进入下一轮角色 LLM 的对话历史**

> 理由：激活是被动维稳行为，不是对话本身；放进角色 LLM 上下文会让模型误以为"AI 上一轮说过这句话需要承接"，影响话术连贯性。

实施：engine 在 call_session 内维护**两个集合**：
- `dialog_history` —— 喂给角色 LLM（不含 silence_activation / silence_hangup_phrase 等系统话术）
- `full_transcript` —— 写 DB（含全部）

### 10.5 配置字段（加到 campaign 表）

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `silence_threshold_ms` | int | 5000 | 沉默触发阈值 |
| `max_silence_activations` | int | 2 | 单通电话激活上限（与其他章节共享） |
| `silence_phrases` | JSONB array | `["请问您还在吗？","您好，请问能听到吗？"]` | 激活话术库，顺序使用 |
| `silence_hangup_phrase` | text | `"那今天就先这样，稍后联系，再见。"` | 上限达到后的告别话术 |

### 10.6 与其他模块的交互

| 模块 | 关系 |
|---|---|
| **打断判定** | 激活 TTS 播放期间，用户开始说话走标准打断判定（与普通 SPEAKING 同逻辑） |
| **转人工** | 转人工触发优先级 > 沉默激活；任一种转人工触发命中时直接进 TRANSFERRING，不等沉默 |
| **超时挂断** | 沉默激活处理"完全沉默"；用户一直说但都被判定为"非打断/无效内容"由独立的 `max_no_progress_seconds`（在 §4 业务规则）控制 |

---

## 11. Transcript 数据格式

### 11.1 存储模型概览

| 内容 | 存储位置 |
|---|---|
| 通话事件流（对话 + 状态变化 + 实时行为） | `call_record.transcript` (JSONB array) |
| AI 三层管线的候选 / 裁判 / 润色详细 trace | 独立表 `pipeline_trace`（按通话 + 轮次） |
| 整通录音音频 | OSS（`call_record.recording_url`） |

> **设计权衡：** transcript 与 pipeline_trace 分离，避免管线的大量调试数据污染 transcript JSONB。运营和坐席只看 transcript；调试时按 `call_record_id + turn_id` 关联到 pipeline_trace。

### 11.2 Transcript 事件类型

每个事件包含共同字段：

```ts
{
  type: string         // 见下表
  ts: number           // 相对通话开始的毫秒数
  // ... 各类型独有字段
}
```

**完整事件类型枚举：**

| type | 字段（除共同字段外） | 说明 |
|---|---|---|
| `greeting` | text, audio_duration_ms | 开场白播放 |
| `user_speech` | text, asr_confidence, duration_ms | 用户一段语音的 ASR 终态结果 |
| `ai_reply` | text, turn_id, selected_role_config_id, goal_achieved, goal_type, extracted, is_wrap_up | AI 回复（润色后） |
| `interruption` | interrupted_event_id, user_text_at_interruption | 用户打断 |
| `filler` | text, filler_phrase_id, duration_ms | 垫词播放 |
| `default_reply_used` | text, reason | 全部裁判否决，走默认回复 |
| `silence_activation` | text, activation_index | 沉默激活话术 |
| `transfer_initiated` | trigger_type, trigger_detail | 转人工触发命中 |
| `transfer_marked` | handoff_task_id | 衔接话术播完、handoff_task 已派发，准备主动挂断 |
| `goal_achieved` | goal_type, extracted | 目标达成（与 ai_reply 重复时只一次，但会作为里程碑事件单独标记） |
| `wrap_up_started` | rounds_remaining, seconds_remaining | 进入收尾 |
| `wrap_up_completed` | reason (`max_rounds`/`max_seconds`) | 收尾结束 |
| `hangup` | reason, initiated_by (`user`/`ai`) | 挂断 |

**示例片段：**

```json
[
  {"type": "greeting", "ts": 0, "text": "您好，我是...", "audio_duration_ms": 3200},
  {"type": "user_speech", "ts": 3500, "text": "你好", "asr_confidence": 0.95, "duration_ms": 800},
  {"type": "filler", "ts": 4400, "text": "让我看一下", "filler_phrase_id": 12, "duration_ms": 1200},
  {"type": "ai_reply", "ts": 5600, "turn_id": 1, "text": "我们这边有...",
   "selected_role_config_id": 5, "goal_achieved": false, "goal_type": "", "extracted": {}, "is_wrap_up": false},
  {"type": "user_speech", "ts": 9200, "text": "周三下午可以吗", "asr_confidence": 0.92, "duration_ms": 1300},
  {"type": "ai_reply", "ts": 11000, "turn_id": 2, "text": "好的，那周三下午 3 点见",
   "goal_achieved": true, "goal_type": "appointment", "extracted": {"time": "2026-05-06T15:00"}, "is_wrap_up": false},
  {"type": "wrap_up_started", "ts": 11100, "rounds_remaining": 2, "seconds_remaining": 15000},
  {"type": "ai_reply", "ts": 13000, "turn_id": 3, "text": "那我们就这样，回头联系", "is_wrap_up": true},
  {"type": "hangup", "ts": 16000, "reason": "wrap_up_completed", "initiated_by": "ai"}
]
```

### 11.3 dialog_history vs full_transcript

engine 内存态维护**两个集合**，挂断时合并落 DB：

| 集合 | 用途 | 包含事件 |
|---|---|---|
| `dialog_history` | 拼接给角色 LLM 的对话历史 | `greeting`, `user_speech`, `ai_reply`（含 wrap_up 期间，因为收尾对话也是对话本身） |
| `full_transcript` | 写 `call_record.transcript` 字段 | 全部事件（含状态变化和系统行为） |

> 详见 §10.4 沉默激活与角色 LLM 上下文的关系。

### 11.4 pipeline_trace 表

```
pipeline_trace
├─ id
├─ call_record_id
├─ turn_id                  ← 与 ai_reply.turn_id 对应
├─ ts_start, ts_end         ← 管线开始/结束时刻
├─ user_input(text)         ← 触发本轮的用户语音文本
├─ role_candidates(JSONB)   ← N 份角色 LLM 输出
│     [{role_config_id, prompt_version_id, raw_output, parsed_json,
│       duration_ms, prompt_tokens, completion_tokens, error}]
├─ judge_results(JSONB)     ← 每个候选 × M 个裁判的判定
│     [{candidate_index, role_config_id (judge), prompt_version_id,
│       passed, reason, duration_ms}]
├─ polish_input(JSONB)      ← 通过裁判的候选集合
├─ polish_output(text)      ← 润色后最终 reply
├─ polish_duration_ms
├─ polish_role_config_id, polish_prompt_version_id
├─ final_selected_candidate_index
└─ created_at
```

**用途：**
- 调试：为什么某通通话没达成目标 → 查 pipeline_trace 看每轮候选和裁判结果
- 优化：分析哪些裁判规则误杀率高，哪些角色 prompt 表现差
- v1 仅查询，不展示在普通管理界面（仅"高级"调试视图）

### 11.5 录音存储

**录音方式：** modem-controller 在拨号建立后启动 PCM 录音，整通通话录成单个 wav 文件，挂断后由 worker 异步上传 OSS。

**存储路径：**
```
OSS / S3:
  isales/recordings/{YYYY-MM-DD}/{call_record_id}.wav
```

**call_record.recording_url：** 存 OSS 完整路径或带签名 URL。

**回放：** transcript 事件的 `ts` 字段是相对通话开始的毫秒偏移，前端播放器可据此定位录音任意时刻。

### 11.6 PII 与脱敏（v1 不做）

电话号码、姓名、地址等敏感信息 v1 直接明文存 transcript / pipeline_trace。脱敏 / 加密 / 留存策略列入 §18 v1 范围外。

---

## 12. 跟进与重试策略

### 12.1 概念区分

**重试**和**跟进**是两个独立机制，独立计数、独立间隔策略、独立上限。

| 概念 | 定义 | 触发条件 | 配置入口 |
|---|---|---|---|
| **重试 (retry)** | 同一通电话因技术原因失败后再次拨打 | hangup_cause ∈ {no_answer, busy, network_error, ...} | `campaign.retry_*` |
| **跟进 (follow-up)** | 通话已正常完成但目标未达成，按业务策略再次联系 | call ended normally + `goal_achieved == false` | `campaign.follow_up_*` |

### 12.2 重试策略

**进入重试的条件**（来自 modem-controller 上报的 `hangup_cause`，由 GSM cause 映射，详见 §14.8）：

| 重试 | 不重试 |
|---|---|
| `no_answer` | 通话已正常接通完成（即使目标未达，走跟进而非重试） |
| `user_busy` | 用户主动挂断（接通后立即挂） |
| `network_out_of_order` | 明确拒接（如 `call_rejected`） |
| `temporary_failure` | `do_not_call` 状态的 lead |

**间隔策略：指数退避 + 最大次数**
- Campaign 配置 `retry_intervals` (JSONB array of minutes) 和 `retry_max_count`
- 第 N 次重试间隔 = `retry_intervals[N-1]`；超出数组长度时使用最后一项
- N >= retry_max_count 时进入 `lead.status = failed`

### 12.3 跟进策略

**进入跟进的条件：**
- 通话正常结束（hangup reason ∈ `normal_clearing` / `wrap_up_completed` / `silence_max_reached`）
- `call_summary.goal_achieved == false`
- `lead.status != do_not_call`

**间隔策略：固定间隔 + 最大次数**
- Campaign 配置 `follow_up_interval_days` 和 `follow_up_max_count`
- 第 N 次跟进时间 = 上一次通话结束时间 + N × `follow_up_interval_days`
- N >= follow_up_max_count 时进入 `lead.status = follow_up_exhausted`

**跟进时的 prompt 增强：**

system prompt 末尾顺序追加（紧跟可能的收尾指令之前）：
```
【跟进上下文】
这是对该用户的第 {N} 次跟进。上次通话结束于 {timestamp}。
请根据下面的【上次通话纪要】调整开场和后续话术，避免重复内容。
```

> 上次通话摘要由 scheduler 在 dial 队列消息中携带（见 §6.2 user message 顶部独立段）。

### 12.4 "勿打" 识别与处理

**识别机制（双重，OR 关系）：**

1. **关键词命中**（同步，每次 ASR 终态结果检测）
   - `campaign.do_not_call_keywords`（JSONB array，如「不要打」「别打」「勿打」「再打投诉」）
   - 命中即标记
2. **独立判定 LLM**（每轮 PROCESSING 并行）
   - `campaign.do_not_call_llm_enabled` + `do_not_call_llm_prompt_version_id`
   - LLM 输出 `{"do_not_call": true}` 即标记

**任一命中即生效。**

**处理流程：**
- 当前通话立即进入收尾流程（不立刻挂断，礼貌告别）
- `lead.status = do_not_call`
- 移除该 lead 所有未来重试和跟进任务
- 触发 `do_not_call_marked` 事件 → 可被 callback_config 订阅推到 CRM

### 12.5 lead 状态机

```
new → queued → calling
                  │
                  ├─ 重试场景 ───────── retrying ──→ queued (按间隔等待)
                  │
                  ├─ 重试上限 ───────── failed
                  │
                  ├─ 通话完成 + 达成 → completed
                  │
                  ├─ 通话完成 + 未达 → following_up ──→ queued (按间隔等待)
                  │
                  ├─ 跟进上限 ───────── follow_up_exhausted
                  │
                  ├─ 勿打命中 ───────── do_not_call
                  │
                  └─ 转人工成功 ─────── transferred
```

**终态：** `completed` / `failed` / `follow_up_exhausted` / `do_not_call` / `transferred`。

### 12.6 配置字段（加到 campaign 表）

| 字段 | 类型 | 说明 |
|---|---|---|
| `retry_intervals` | JSONB array | 各次重试的间隔分钟数 |
| `retry_max_count` | int | 重试次数上限 |
| `follow_up_interval_days` | int | 每次跟进的间隔天数 |
| `follow_up_max_count` | int | 跟进次数上限 |
| `do_not_call_keywords` | JSONB array | 勿打关键词列表 |
| `do_not_call_llm_enabled` | bool | 是否启用独立判定 LLM |
| `do_not_call_llm_prompt_version_id` | FK / null | 独立 LLM 的 prompt 版本引用 |

### 12.7 调度数据流

```
isales-scheduler 主循环
   │
   ▼
扫描 campaign in active 状态
   │
   ▼
对每个 campaign：
  1. 取 leads where status ∈ {new, retrying, following_up}
     AND next_call_at <= now
  2. 检查可通话时间窗口（详见 §13 时间窗口）
  3. 检查全局并发计数器（Redis INCR）
  4. 调 telephony-api `/devices/select` 选 device（含 caller_id）
  5. 组装 dial 消息：
       - lead 基本信息
       - is_follow_up + follow_up_count
       - 历史通话纪要（如果是跟进）
       - 当前 prompt_versions 快照
  6. push 到 engine:dial 队列
```

worker 在通话完成（call_record 落 DB）后：
- 根据 hangup_cause 和 goal_achieved 决定 lead 状态流转
- 若进 `retrying` / `following_up`，计算 `next_call_at`，写回 lead
- 若命中 `do_not_call`，清理该 lead 未来所有调度任务

---

## 13. 可通话时间窗口

### 13.1 配置模型

Campaign 配置 N 个时间窗口，每个窗口指定星期几 + 起止时间。`campaign.time_windows`（JSONB array）：

```json
{
  "time_windows": [
    {"days": ["mon","tue","wed","thu","fri"], "start": "09:00", "end": "12:00"},
    {"days": ["mon","tue","wed","thu","fri"], "start": "14:00", "end": "18:00"},
    {"days": ["sat"],                          "start": "10:00", "end": "16:00"}
  ]
}
```

### 13.2 时区

**统一服务器时区**（部署侧设定，如 `Asia/Shanghai`）。
- 所有窗口判定、节假日、`next_call_at` 均按服务器时区解读
- 不引入 lead 级时区
- 跨时区场景（海外用户）列入 §18

### 13.3 节假日

**全局 `holiday` 表**：

```
holiday
  ├─ id
  ├─ date         ← YYYY-MM-DD
  ├─ name         ← 春节 / 中秋 / ...
  ├─ region       ← v1 仅 CN_mainland
  └─ created_at
```

**Campaign 配置：** `respect_holidays`（bool，default true）—— 是否遵从全局节假日表。

scheduler 判断"是否在窗口内"时：当日命中 holiday 且 `respect_holidays=true` → 视为窗外。

### 13.4 窗外 lead 的调度

**策略：推迟到下个窗口开始时刻。**

scheduler 扫描到 lead `next_call_at <= now` 但当前不在任何窗口内时：
- 计算当前时间之后**最近的窗口开始时刻**（考虑节假日、跨日、跨周）
- 更新 `lead.next_call_at = 该时刻`
- 本次不拨打

### 13.5 跨窗口边界保护

通话进行中跨过窗口结束时刻：
- **不强制中断**正在进行的通话（自然结束）
- scheduler 在窗外时**不再分配新 lead**给 engine

### 13.6 配置字段

| 字段 | 类型 | 说明 |
|---|---|---|
| `time_windows` | JSONB array | 见 §13.1 |
| `respect_holidays` | bool | 是否遵从全局 holiday 表 |

新增表：`holiday`（结构见 §13.3）

---

## 14. 通话设备硬件层

### 14.1 总体形态

- **硬件**：USB GSM Modem（如华为 E1750/E173 等支持 PCM over USB 的型号），每个 modem 插一张 SIM 卡
- **v1 规模**：单主机 ≤ 8 路并发
- **不使用** FreeSWITCH / Asterisk / chan_dongle 等开源 PBX —— 自研控制层
- **承载于 isales-telephony 仓库**，作为独立进程 `modem-controller` 运行（与 `telephony-api` 同仓库不同 deployable）

### 14.2 modem-controller 职责

```
┌────────────────────────────────────────────────────────────────┐
│                      modem-controller                           │
│                                                                 │
│  ┌──────────────────┐    ┌──────────────────────────────────┐  │
│  │   udev 监听器     │    │       engine IPC 服务             │  │
│  │                  │    │   Unix socket 或 localhost WS     │  │
│  │ USB 插拔事件 →   │    │                                   │  │
│  │ device 表状态同步 │    │   接收 engine 指令：               │  │
│  └──────────────────┘    │     - dial(device_id, number)     │  │
│                          │     - hangup(device_id)           │  │
│  ┌──────────────────┐    │   推送 engine 事件：               │  │
│  │   AT 命令通道     │    │     - call_progress / connected   │  │
│  │ /dev/ttyUSB* 串口 │◄───┤     - remote_hangup               │  │
│  │ - 拨号 ATD        │    │     - signal_lost                 │  │
│  │ - 挂断 ATH        │    │   双向 PCM 音频流：                 │  │
│  │ - 状态轮询 AT+CSQ │    │     - upstream (用户语音 → ASR)   │  │
│  │ - SIM 状态查询    │    │     - downstream (TTS → 用户)     │  │
│  └──────────────────┘    └──────────────────────────────────┘  │
│                                                                 │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │                  PCM 音频管道                                │ │
│  │  USB audio device (ALSA /dev/snd/pcmC*D*c) ◄──► 内存缓冲   │ │
│  │  - 上行：8kHz 16-bit linear PCM → 重采样 16kHz → engine    │ │
│  │  - 下行：engine TTS PCM → 重采样 8kHz → ALSA playback     │ │
│  └────────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────┘
```

### 14.3 device 状态机

```
unknown ──────────► detected ──────► registered ──────► idle ──────► busy
   ▲                  │                  │              │            │
   │                  │ AT 命令初始化    │              │ engine     │ 通话结束
   │ udev removed     │ 失败             │              │ dial       │
   │                  ▼                  │              ▼            │
   │              error ◄────────────────┘             dialing       │
   │                  │                                  │            │
   │                  │ retry / 替换 SIM                 │            │
   │                  ▼                                  ▼            │
   └──── offline ◄──── flagged ◄──── 信号差/接通率低    in_call ──────┘
```

**状态字段：**
- `unknown` —— 未识别
- `detected` —— udev 检测到，未初始化
- `registered` —— AT 初始化成功，已注册到运营商网络
- `idle` —— 空闲可拨打
- `dialing` —— 正在外呼
- `in_call` —— 通话中
- `busy` —— 用 idle/dialing/in_call 之一表达即可，不需独立
- `offline` —— USB 已拔出
- `flagged` —— 被 worker 标记健康度低
- `error` —— 初始化失败

### 14.4 SIM 卡资料化管理

`sim_card` 表覆盖以下属性：

| 字段 | 说明 |
|---|---|
| iccid | SIM 卡硬件唯一标识，热插拔的"身份证" |
| imsi | 国际移动用户识别码 |
| phone_number | 该 SIM 对应的外显号码（caller_id 来源） |
| carrier | 运营商（移动/联通/电信） |
| plan | 套餐说明（自由文本或结构化） |
| balance | 余额（定期 AT 命令查询） |
| signal_strength | 最近一次 AT+CSQ 结果 |
| status | active / suspended / arrears / flagged |
| last_checked_at | 最后状态查询时刻 |

**device_sim_binding 表** 记录绑定历史：
- 字段：`device_id`, `sim_card_id`, `is_active`, `bind_at`, `unbind_at`
- 同一 device 同一时刻只能有一条 `is_active=true`
- udev 检测到 SIM 变更（比较 ICCID）时自动新增绑定记录

### 14.5 udev 自动检测

modem-controller 启动时：
1. `pyudev` 监听 USB 设备事件
2. 对每个 `add` 事件：
   - 通过 ttyUSB / 设备 ID 识别是 GSM modem
   - 发 `AT+CCID`, `AT+CGMI`, `AT+CGSN` 拿到 ICCID / 厂商 / IMEI
   - 查 DB 是否已注册：
     - 已有 device 记录 → 更新 `last_seen_at`、状态置 `idle`
     - 新设备 → 创建 device 记录，状态置 `detected`
   - 检查 SIM 是否变更：上次绑定的 ICCID ≠ 当前 → 关闭旧 binding，建新 binding
3. 对每个 `remove` 事件：
   - 找到对应 device → 状态置 `offline`
   - 关闭 active binding 的 `unbind_at`

### 14.6 engine ↔ modem-controller IPC 协议

**通道**：Unix socket（单主机部署） + JSON 消息

**指令（engine → modem-controller）：**
```json
{"cmd": "dial",   "device_id": 3, "number": "13800138000", "session_id": "abc"}
{"cmd": "hangup", "session_id": "abc"}
{"cmd": "audio_downstream", "session_id": "abc", "pcm_chunk": "<base64>"}
```

**事件（modem-controller → engine）：**
```json
{"event": "call_progress", "session_id": "abc", "state": "ringing"}
{"event": "connected",     "session_id": "abc"}
{"event": "audio_upstream","session_id": "abc", "pcm_chunk": "<base64>"}
{"event": "remote_hangup", "session_id": "abc", "cause": "no_answer"}
{"event": "device_error",  "session_id": "abc", "code": "signal_lost"}
```

> 音频流也走 IPC（v1 简化）。后期可改为单独的 Unix domain socket 流通道（pcm_upstream / pcm_downstream），减少 JSON 编解码开销。

### 14.7 选 device API（telephony-api）

```
POST /devices/select
  Request: { campaign_id }
  Response: { device_id, phone_number }
```

**选择策略：**
- 取该 Campaign 关联的 device（通过 `campaign_device` 表）
- 过滤 `status=idle` 且 `device_sim_binding.is_active=true`
- 选 `last_call_at` 最早的（保持负载均衡）
- 没有空闲 → 返回 `503 no_idle_device`

### 14.8 hangup_cause 映射

GSM modem 的 hangup cause（从 AT 命令或 CEND 事件获取）映射到 §12.2 的重试场景：

| GSM cause | 映射 |
|---|---|
| `no answer` / `no carrier` | `no_answer` → 重试 |
| `busy` | `user_busy` → 重试 |
| `network failure` / `signal lost` | `network_out_of_order` → 重试 |
| `normal call clearing` | `normal_clearing` → 走跟进逻辑 |
| `call rejected` | `call_rejected` → 不重试 |

### 14.9 v1 不做的硬件能力

- **短信**：v1 不实现 SMS 发送/接收，列入 §18
- **多主机扩展**：单主机部署，跨主机调度的 device 选择 v2 处理
- **硬件级负载均衡**：v1 仅按 last_call_at 简单调度
- **GSM 信道质量自动切换**：信号差只标记 flagged，不自动切其他 device

---

## 15. 数据模型（核心表）

| 表 | 关键字段 | 归属服务 |
|----|---------|---------|
| `campaign` | name, voice_id, default_replies(JSONB), concurrency, time_windows(JSONB), extraction_fields(JSONB), max_silence_activations, silence_threshold_ms, silence_phrases(JSONB), silence_hangup_phrase, max_no_progress_seconds, wrap_up_max_rounds, wrap_up_max_seconds, wrap_up_closing_phrases(JSONB), interruption_whitelist(JSONB), interruption_min_duration_ms, max_continuous_interruptions, continuous_interruption_strategy, transfer_keyword_enabled, transfer_keywords(JSONB), transfer_intent_enabled, transfer_intent_threshold, transfer_round_enabled, transfer_round_threshold, transfer_llm_enabled, transfer_llm_prompt_version_id, transfer_phrases(JSONB), retry_intervals(JSONB), retry_max_count, follow_up_interval_days, follow_up_max_count, do_not_call_keywords(JSONB), do_not_call_llm_enabled, do_not_call_llm_prompt_version_id, respect_holidays | api |
| `holiday` | date, name, region | api |
| `agent` | name, login_user, status (online/offline) | telephony |
| `handoff_task` | call_record_id, agent_id (nullable), trigger_type, trigger_detail, status (pending/in_progress/completed/dropped), created_at, picked_up_at, completed_at | worker |
| `role_config` | campaign_id, kind(role/judge/polish), model, current_prompt_version_id, temperature, top_p, ext_params(JSONB), enabled | api |
| `prompt_version` | scope_type, scope_id, content, created_at, created_by, is_active | api |
| `pipeline_trace` | call_record_id, turn_id, ts_start, ts_end, user_input, role_candidates(JSONB), judge_results(JSONB), polish_input(JSONB), polish_output, polish_duration_ms, polish_role_config_id, polish_prompt_version_id, final_selected_candidate_index | engine |
| `lead` | name, phone, source, custom_data(JSONB), status, retry_count, follow_up_count, next_call_at, last_hangup_cause | api |
| `call_record` | lead_id, campaign_id, caller_id, status, started_at, ended_at, duration, transcript(JSONB), recording_url, transfer_status, transfer_reason, transfer_target, **wrap_up_started_at, prompt_versions(JSONB)** | engine |
| `call_summary` | call_record_id, summary_text, extracted_fields(JSONB), goal_achieved, goal_type | worker |
| `voice_model` | name, provider, voice_id, sample_url | api |
| `filler_set` | campaign_id, name, sort_order | api |
| `filler_phrase` | filler_set_id, phrase, audio_url, generation_status | api |
| `callback_config` | campaign_id, name, trigger, url, method, headers(JSONB), payload_template(JSONB), retry_policy(JSONB), enabled | api |
| `callback_log` | callback_config_id, call_record_id, status, request_body, response_code, response_body, retry_count, next_retry_at | worker |
| `device` | name, usb_port, modem_model, imei, status (online/offline/flagged), last_seen_at | telephony |
| `sim_card` | iccid, imsi, phone_number, carrier, plan, balance, signal_strength, status, last_checked_at | telephony |
| `device_sim_binding` | device_id, sim_card_id, is_active, bind_at, unbind_at | telephony |
| `campaign_device` | campaign_id, device_id | telephony |

> 数据库统一 PostgreSQL；迁移由 `isales-common/alembic` 管理。

---

## 16. 服务间通信

| 从 | 到 | 通道 | 用途 |
|----|-----|------|------|
| scheduler | engine | Redis Queue | "拨打这条线索"（消息体含 lead 信息 + 历史摘要） |
| engine | worker | Redis Queue | "通话已结束，请处理" |
| api | engine | Redis Pub/Sub | 实时控制（手动挂断、转人工指令） |
| engine | api | Redis Pub/Sub | 通话事件推送（状态变更、ASR 文本） |
| api | scheduler | Redis Queue | 启动/暂停 Campaign |
| scheduler | telephony-api | HTTP | 拨号前选 device（含 caller_id） |
| engine | modem-controller | **本地 Unix socket / WebSocket** | 拨号、挂断、PCM 音频流双向 |
| modem-controller | telephony DB | 直连 | 设备状态 / SIM 状态实时回写 |
| modem-controller | USB GSM modem | AT 命令 (`/dev/ttyUSB*`) + 音频 (ALSA) | 物理设备控制 |
| worker | 外部 | HTTP | Webhook 回调外部业务系统 |
| 全部 | PostgreSQL | 直连（通过 isales-common 模型） | 数据持久化 |
| 全部 | Redis | 直连 | 队列、缓存、计数器 |

---

## 17. 关键决策与权衡（备忘）

- **多仓库 vs Monorepo**：选多仓库，因为单仓库代码量在 Claude Code 单会话上下文中难以高效迭代；isales-common 用 pip 包发布到内部 PyPI（或 git 直装）。
- **AI 管线层数**：3 层（角色 → 裁判 → 润色），不增加更多层以控制延迟。
- **PK 不在角色级配音色**：避免一通电话音色频繁切换，统一在 Campaign 级。
- **裁判失败不重试 LLM**：避免延迟雪崩，直接走默认回复兜底。
- **历史摘要由 scheduler 注入而非 engine 查 DB**：减少 engine 的 DB 依赖，便于 engine 横向扩展。
- **全局并发计数器在 Redis**：单 engine 进程的本地计数无法跨实例。
- **engine 单点故障**：短期靠 systemd/supervisor 重启；中期支持多实例 + 会话亲和（Redis hash slot）。
- **目标判定不在润色层做投票合并**：润色直接继承被选中候选的标记，不对 N 个候选的 `goal_achieved` 做多数投票。理由：实现简单、延迟低；误报由角色 prompt 设计 + 收尾期间用户反应（即使 AI 误以为达成，用户在收尾对话中也会自然纠正）兜底。代价：单次单轮误报概率高于投票方案，需在 prompt 中强约束判定标准。
- **不用 FreeSWITCH/Asterisk，自研 USB GSM modem 控制层**：硬件方案是 USB modem + SIM 卡直插主机；v1 单主机 ≤8 路。理由：成熟 PBX (Asterisk + chan_dongle) 虽稳定但额外引入 PBX 学习曲线和音频路径复杂度；自研可直接 AT 命令 + ALSA PCM，控制粒度更细。代价：底层硬件控制和音频管道全部自己写，调试成本高；列为 §14 单独章节。
- **modem-controller 与 telephony-api 同仓库不同进程**：减少新仓库带来的部署/CI 复杂度。代价：CI 中两个 entry points 要分别启停。后期若 modem-controller 复杂度上升，再拆出独立仓库 isales-modem-controller。
- **v1 转人工衰减为「标记 + 通知」，不做实时桥接**：自研 USB GSM 方案下没有 SIP/PBX 设施，实时桥接需引入额外复杂度（自研 SIP 软话机或局部破例引入 FS）。v1 仅做"播衔接话术 → 派发 handoff_task → 主动挂断"，坐席 Web UI 看到任务后从其他业务电话系统手动回拨。三种实时桥接方案（GSM AT+CHLD / 自研 SIP / FS bridge）列入 §18 v2。

---

## 18. 已识别但暂不在 v1 范围内

- 多语言支持（v1 仅普通话）
- 实时声纹识别（用于打断判定增强）
- 角色 prompt 的 A/B 实验框架
- 通话录音的实时转写流（v1 离线 ASR 后处理）
- engine 多实例 + 多主机扩展的会话亲和与跨机调度
- SMS 收发能力（v1 仅语音）
- 跨时区 / 海外通道
- 多租户、计费、配额管理（SaaS 化能力）
- 商业系统对比识别出的 P1/P2 能力：自动质检、情绪识别触发转人工、监控告警大盘、A/B 测试、沙盒模式（详见对比备忘 GAPS.md，待补）
- **转人工实时桥接**：v1 仅做"标记+通知"。v2 候选方案三选一：
  - GSM 呼叫转接（AT+CHLD=4）—— 最贴近原生体验，依赖运营商支持
  - 自研 SIP 软话机集成 —— modem-controller 同时作为 SIP 端点，把 GSM PCM 桥到坐席 SIP
  - 引入 FreeSWITCH 仅做 bridge —— 局部破例，但增加运维面
