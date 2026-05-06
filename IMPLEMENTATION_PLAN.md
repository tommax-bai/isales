# iSales 分阶段实施计划

> 配合 `DESIGN.md` 使用。本文档定义"做什么、按什么顺序做、做到什么程度算完成"。
>
> 总体策略：**自下而上**——先共享库 → 再周边服务 → 最后实时通话引擎。每个仓库独立 git 历史，isales-common 作为内部包被其他 6 个服务依赖。

---

## 阶段顺序总图

```
阶段 0：本地基础设施 (Docker Compose)
   │
   ▼
阶段 1：isales-common ──────────────────────────┐
   │ (模型/Schema/Provider ABC/迁移)            │ 被以下所有阶段依赖
   ▼                                           │
阶段 2：isales-telephony  +  isales-api        │
   │ (telephony-api: device/SIM CRUD;          │
   │  modem-controller: udev + AT 命令骨架;     │
   │  isales-api: 管理后台 CRUD)                │
   ▼                                           │
阶段 3：isales-scheduler  +  isales-worker     │
   │ (调度 + 异步后处理，可不依赖 engine 单测)   │
   ▼                                           │
阶段 4：isales-engine 骨架 (状态机 + Mock 管线) │
   │                                           │
   ▼                                           │
阶段 5：isales-engine AI 管线接通真实 Provider  │
   │ (LLM/ASR/TTS 真实接入)                    │
   ▼                                           │
阶段 6：modem-controller 真实硬件接入          │
   │ + engine ↔ modem-controller IPC 打通     │
   ▼                                           │
阶段 7：isales-web ────────────────────────────┘
   │
   ▼
阶段 8：端到端联调 + 灰度
```

---

## 阶段 0：本地基础设施（半天）

**目标：** 一键起本地开发环境。

**产出：**
- 仓库根目录新增 `docker-compose.yml`，包含 PostgreSQL 15 + Redis 7（**不再包含 FreeSWITCH**）
- `.env.example` 列出所有需要的环境变量
- `Makefile` 提供 `make up / down / logs / psql / redis-cli` 等快捷命令
- 文档列出本地开发依赖的系统包：`libudev`, `libasound2-dev`, `pyudev`, `pyserial`（for AT 命令）

**验收：**
- `make up` 后 `psql -h localhost -p 5432 -U isales` 能连
- `redis-cli ping` 返回 PONG
- 真实硬件验收推迟到阶段 6（v1 设备开发机插一枚 USB GSM modem 即可）

---

## 阶段 1：isales-common ✅ 已完成（v0.1.0）

> 实施细节迁移到 OpenSpec change `init-isales-common`（已归档于 `openspec/changes/archive/`）；本节保留为历史记录。下游服务的引用样例与版本管理见 `isales-common/README.md`。

**目标：** 所有数据模型、Provider 接口、迁移脚本一次性沉淀，供其他仓库依赖。

**产出（按子模块）：**

| 子模块 | 内容 |
|--------|------|
| `isales_common/models/` | 全部 12 张表的 SQLAlchemy 模型（见 DESIGN.md §5） |
| `isales_common/schemas/` | Pydantic v2 请求/响应模型，按资源拆分（campaign.py / lead.py / call.py ...） |
| `isales_common/providers/` | ASR / TTS / LLM 三套 ABC（含异步 session 抽象） |
| `isales_common/enums.py` | 状态枚举（CallStatus / RoleKind / TransferStatus 等） |
| `isales_common/utils/` | 号码归一化、音频格式工具、加解密（用于 sip 密码）、Redis client factory |
| `alembic/` | 初始迁移：12 张表全部建好；后续每个 PR 增量 |
| `pyproject.toml` | 用 hatchling，声明依赖 SQLAlchemy 2 / Pydantic 2 / asyncpg / redis / aiohttp |

**验收：**
- `pip install -e .` 在另一个空环境可成功 import 所有模块
- `alembic upgrade head` 在空数据库上跑通
- 单元测试覆盖：Provider ABC 的契约测试（用一个内存 mock 实现验证接口）

**修改顺序：**
1. 建仓库 + pyproject.toml + 基础目录
2. 写 enums.py
3. 写 models/（按表的依赖关系：campaign → role_config → lead → call_record → ...）
4. 写 schemas/（一一对应 models）
5. 写 providers/ ABC
6. 写 utils/
7. alembic init + autogenerate 初始迁移
8. pytest 跑 contract tests

---

## 阶段 2：isales-telephony + isales-api（并行，3~5 天）

> 这两个服务都是 CRUD 重、实时性轻，可由两人/两会话并行推进。
>
> 边界澄清见 OpenSpec change `clarify-stage2-boundaries`（已归档）。isales-common v0.1.2 增量需求（`device.last_call_at` 列 + `DeviceSelectRequest/Response` schema + alembic 迁移）由 `impl-telephony` change 承担。

### 2A. isales-telephony（一仓库两进程）

**目标：** device + SIM 管理服务能独立运行；modem-controller 进程骨架就位（v1 阶段 2 仅做 mock，真实硬件接入留到阶段 6）。

**进程 1：telephony-api（FastAPI）**
- 路由：
  - `/devices` CRUD（USB 端口、modem 型号、IMEI）
  - `/sim-cards` CRUD（ICCID、IMSI、phone_number、运营商、套餐、余额）
  - `/device-sim-bindings` 查询（含历史）
  - `POST /devices/select`：按 Campaign + 空闲状态返回 device_id + phone_number
- 设备健康监控：定时任务扫近 N 通接通率 < 阈值的 device，置 flagged

**进程 2：modem-controller（守护进程）**
- udev 事件监听器（pyudev）骨架，事件打日志、写 device.status
- AT 命令客户端（pyserial），先抽象接口，阶段 6 接真实硬件
- IPC 服务（Unix socket），先暴露 `dial / hangup / status` 端点（mock 实现）
- 启动时从 DB 加载 device 列表，尝试匹配 USB 端口

**验收：**
- [x] telephony-api 跑通 device / sim_card CRUD（impl-telephony PR #3）
- [x] modem-controller 启动不报错、能响应 IPC 心跳（PR #6 status round-trip 测试）
- [x] 插拔 GSM USB 设备能在日志/DB 里看到 udev 事件（PR #8；macOS 用 fake_events 验证；真实插拔留到 stage 6 / Linux 部署后）
- [x] `pytest` 全绿（mock 硬件层）— 35 passed / mypy 0 / ruff 0
- [x] /devices/select 并发安全（PR #4 with FOR UPDATE SKIP LOCKED；并发 11 测试 10 + 1×503）
- [x] systemd unit + 部署文档就位（PR #9）

### 2B. isales-api

**目标：** 管理后台所有 CRUD 完成；engine/scheduler 还没起来时也能用。

**产出：**
- FastAPI 应用，路由：
  - `/campaigns` CRUD（含 role_config / filler_set / callback_config 嵌套管理）
  - `/leads` CRUD + 批量导入 CSV
  - `/voice-models` CRUD + 试听
  - `/calls` 查询（带 transcript / 录音回放）
  - `/analytics/*` 统计聚合
  - `/ws/calls/{campaign_id}` WebSocket，订阅 Redis Pub/Sub 推给前端
- 鉴权：JWT（最小可用，先 admin 一种角色）
- 启动/暂停 Campaign：写 Redis 队列通知 scheduler

**验收：**
- 通过 OpenAPI 文档手动跑通所有 CRUD
- WebSocket 能收到 mock 推送的事件（先用脚本模拟）

---

## 阶段 3：isales-scheduler + isales-worker（并行，3~4 天）

### 3A. isales-scheduler

**目标：** 能从数据库捞 lead，按时间窗口 + 并发限制分发到 engine 队列。

**产出：**
- 调度循环（asyncio）：
  1. 扫描 active campaigns
  2. 对每个 campaign 检查 `time_windows` 是否在窗口内
  3. 检查 Redis 全局并发计数器是否还有余额
  4. 取下一批 leads（含跟进队列：next_follow_up_at <= now）
  5. **打包历史摘要**（查 call_summary 表近 N 次摘要）
  6. 调 telephony 选号 API 拿 caller_id
  7. 写 `engine:dial` 队列
- 跟进策略：通话结束后由 worker 写回 lead.next_follow_up_at；scheduler 只负责按时间触发
- 重试策略：未接通的 lead 按 Campaign 的 retry_policy 重排

**验收：**
- mock engine（消费队列打日志），跑 1 小时不崩，并发数符合配置

### 3B. isales-worker

**目标：** 通话结束的所有异步活儿。

**产出：**
- Celery（broker = Redis）+ 任务：
  - `summarize_call`：用 LLM 生成摘要 + 提取 extraction_fields
  - `process_callbacks`：匹配 callback_config 触发条件，渲染 payload，HTTP POST，失败按 retry_policy 重排
  - `update_lead_state`：写回 lead.status / next_follow_up_at
  - `aggregate_metrics`：定时聚合 analytics 视图

**验收：**
- 用一条手工构造的 call_record（含 transcript）跑完整链路，DB 中 call_summary / callback_log 都正确写入

---

## 阶段 4：isales-engine 骨架（5~7 天，最关键）

**目标：** 状态机 + AI 管线编排能跑通**端到端 mock 通话**（不接真实硬件、不调真 LLM）。

**产出（分子模块）：**

| 子模块 | 内容 |
|--------|------|
| `engine/state_machine.py` | 实现 DESIGN.md §3 的全部状态转换 |
| `engine/call_session.py` | 单通电话的会话对象，持有所有 timer / state / context |
| `engine/session_manager.py` | 全局会话注册表 + Redis 并发计数器 |
| `engine/pipeline/orchestrator.py` | 三层管线编排（含润色失败降级、全部裁判否决兜底） |
| `engine/pipeline/role_llm.py` | N 路并行调用 |
| `engine/pipeline/judge_llm.py` | N×M 并行裁判 |
| `engine/pipeline/polish_llm.py` | 选优+润色 |
| `engine/realtime/filler_manager.py` | 垫词选择和播放控制（可被打断） |
| `engine/realtime/interruption_detector.py` | 白名单 + 时长双条件判定 |
| `engine/realtime/silence_detector.py` | 沉默激活（带次数上限） |
| `engine/transfer/manager.py` | 4 种转人工触发 + TRANSFERRING 状态 |
| `engine/wrapup/manager.py` | WRAPPING_UP 状态、双计数器（轮数+时长）、简化管线、收尾挂断话术 |
| `engine/pipeline/json_parser.py` | 角色 LLM JSON 输出解析 + schema 校验，失败时回退为纯文本 reply（标记字段为空） |
| `engine/queue_consumer.py` | 消费 scheduler 的 dial 队列 |
| `engine/event_publisher.py` | 通话事件推送到 Redis Pub/Sub |

**验收：**
- 用 Mock Provider（输入 → 固定输出）+ Mock 电话（输入 → 模拟 ASR 文本流）跑：
  - 正常对话 5 轮，结束写入 call_record + transcript
  - 触发打断，状态机正确流转
  - 触发沉默激活 2 次后挂断
  - 触发转人工，状态机进入 TRANSFERRING
  - 全部裁判否决，回复用默认话术
  - 润色失败，降级到第一个通过的候选
- 并发跑 10 通 mock 电话，全局计数器准确

---

## 阶段 5：engine 接通真实 Provider（2~3 天）

**目标：** ASR / TTS / LLM 接真实供应商（先选 1 套：阿里云 / 火山 / OpenAI 等）。

**产出：**
- `providers/asr/` `providers/tts/` `providers/llm/` 各 1 套真实实现，继承 isales-common 的 ABC
- 配置文件支持多 provider 切换（Campaign 级 model 字段）
- 流式 ASR：用 WebSocket / gRPC 拿到中间结果，喂给 interruption_detector
- 流式 TTS：拿到首包就开始推到 modem-controller 下行 PCM 通道

**验收：**
- 命令行工具：输入文本 → TTS 出 wav；输入 wav → ASR 出文本
- engine + 真实 LLM 跑 mock 电话，5 轮对话内容合理

---

## 阶段 6：modem-controller 真实硬件接入 + engine IPC 打通（5~7 天）

**目标：** USB GSM modem 真实拨打到手机并完成对话。

**产出（modem-controller 侧）：**
- `modem_controller/at_client.py`：异步 AT 命令客户端，封装 `ATD<number>;` 拨号 / `ATH` 挂断 / `AT+CSQ` 信号查询 / `AT+CCID` ICCID 查询
- `modem_controller/audio_pipe.py`：ALSA PCM 双向管道，处理 8kHz↔16kHz 重采样
- `modem_controller/udev_watcher.py`：USB 插拔实时同步 device.status 和 device_sim_binding
- `modem_controller/ipc_server.py`：Unix socket 服务，向 engine 暴露 dial/hangup/audio 端点
- `modem_controller/recorder.py`：每通通话整段 PCM 录到本地 wav，挂断后由 worker 上传 OSS

**产出（engine 侧）：**
- `engine/telephony_client.py`：连本地 modem-controller IPC，封装 dial/hangup + 双向 PCM 流
- 原拨号流：scheduler → 队列 → engine → telephony-api `/devices/select` → engine 调 modem-controller dial → modem-controller 通过 AT 拨打 → 接通后双向 PCM 流转 → engine 状态机驱动 GREETING / SPEAKING / LISTENING ...

**验收：**
- 单个 USB GSM modem 插入开发机，端到端打通自己手机，至少 3 轮真实对话
- 挂断后录音文件生成、call_record / transcript 正确写入、worker 触发 callback
- 拔插 modem 时 device.status 正确变化，正在通话的 session 收到 device_error 事件并优雅清理

---

## 阶段 7：isales-web（4~6 天）

**目标：** 全部管理面 UI 可用。

**产出（按页面）：**
- 任务管理（Campaign CRUD + 角色/裁判/润色/垫词嵌套配置）
- 线索管理（CSV 导入 / 状态查询 / 跟进时间）
- 音色管理（列表 + 试听）
- 设备管理（device / SIM 卡 / 绑定历史）
- 数据看板（接通率 / 目标达成率 / 通话时长分布）
- 通话监控（WS 实时推送 ASR 文本 + 状态）
- 通话记录（列表 + transcript 详情 + 录音回放 + 提取字段）
- 回调配置（callback_config CRUD + 触发记录查看）

**栈：** Vue 3 + Vite + Element Plus + Pinia + Vue Router

**验收：**
- 所有页面手动走一遍，能完成"建任务 → 导线索 → 启动 → 看监控 → 看记录"的完整流程

---

## 阶段 8：端到端联调 + 灰度（持续）

**清单：**
- [ ] 真实环境压测：100 路并发持续 1 小时不崩
- [ ] engine 重启场景：systemd 自动拉起后 active 通话能正常释放（不留垃圾计数）
- [ ] 号码池频率保护：单号 1 分钟内不超阈值
- [ ] callback 失败重试：模拟外部 API 503，验证按 retry_policy 重排
- [ ] 通话超长保护：超过 max_duration 主动挂断
- [ ] 监控告警：Prometheus 接 engine 关键指标（在播 / 处理中 / 队列堆积）
- [ ] 备份策略：PG 每日备份 + Redis 持久化（AOF）

---

## 可执行修改顺序（精确到 PR 粒度）

下面给出**每个仓库内**应当拆成的 PR 顺序。每个 PR 都应小到可在 1~2 次 Claude Code 会话内完成。

### isales-common（建议 ~6 PR）
1. 仓库初始化 + pyproject + CI 骨架
2. enums + utils（不依赖任何模型）
3. models/ 第一批：campaign / role_config / voice_model / filler_set
4. models/ 第二批：lead / call_record / call_summary
5. models/ 第三批：device / sim_card / device_sim_binding / campaign_device / agent / holiday / callback_config / callback_log
6. schemas/ 全量 + Provider ABC + alembic 初始迁移

### isales-telephony（建议 ~7 PR，一仓库两进程）
1. 仓库骨架 + 两个 entry point（telephony-api / modem-controller） + DB 连接
2. device / sim_card / device_sim_binding CRUD + REST API
3. select-device API + campaign_device 关联 + 集成测试
4. modem-controller 骨架（IPC server + mock dial/hangup）
5. udev 监听 + USB GSM modem 自动注册
6. AT 命令客户端 + 真实拨号 / 挂断
7. ALSA PCM 双向管道 + 端到端真实拨号联调

### isales-api（建议 ~7 PR）
1. FastAPI 骨架 + JWT 鉴权
2. campaign CRUD（含嵌套 role_config / filler_set）
3. lead CRUD + 批量导入
4. voice_model CRUD + 试听
5. call 查询（含 transcript）
6. analytics 聚合
7. WebSocket /ws/calls + Redis Pub/Sub 转发

### isales-scheduler（建议 ~4 PR）
1. 调度主循环 + 时间窗口
2. 全局并发计数器 + 选号集成
3. 历史摘要打包 + 队列写入
4. 重试和跟进策略

### isales-worker（建议 ~4 PR）
1. Celery 骨架 + summarize_call 任务
2. 字段提取（用 LLM JSON Mode）
3. callback_config 匹配 + 异步回调 + 重试
4. analytics 聚合定时任务

### isales-engine（建议 ~11 PR，最复杂）
1. 仓库骨架 + 状态机 stub（含 WRAPPING_UP）+ 单元测试
2. session_manager + 全局并发计数器
3. orchestrator + Mock Provider 三层管线 + JSON 输出解析
4. filler_manager（含被打断逻辑）
5. interruption_detector
6. silence_detector
7. transfer manager + TRANSFERRING 状态
8. **wrapup manager + WRAPPING_UP 简化管线 + 双计数器 + 挂断话术**
9. queue_consumer + event_publisher
10. ASR/TTS/LLM 真实 Provider 实现
11. telephony_client（连 modem-controller IPC）+ 真实硬件端到端拨打

### isales-web（建议 ~8 PR）
1. Vite 骨架 + 路由 + 鉴权
2. 任务管理页（含嵌套配置）
3. 线索管理页 + CSV 导入
4. 音色管理 + 设备管理
5. 数据看板
6. 通话监控（WS 实时）
7. 通话记录 + 回放
8. 回调配置页

---

## 关键风险点

| 风险 | 影响 | 缓解 |
|------|------|------|
| engine 单点故障 | 全部活跃通话断开 | systemd 自动重启；后续多实例 + 会话亲和 |
| LLM 延迟尖刺 | 用户感知卡顿 | 垫词覆盖；超时阈值后用默认回复 |
| ASR 错误率 | 打断误判 | 白名单 + 时长双条件；连续打断保护 |
| USB GSM modem 不稳定 / 重连 | 通话突然中断 | udev 实时监听 + device 状态机 + engine session 优雅清理 |
| 自研 PCM 音频管道时延 | 用户感知卡顿 | ALSA buffer 调优；首次接入时基准压测时延，超 200ms 端到端单独排查 |
| AT 命令冲突 | 多通话同时操作同一 modem 串口出错 | 单 modem 串口序列化访问，加 asyncio Lock |
| SIM 卡余额耗尽 | 拨号失败 | sim_card.balance 定期查询 + 阈值告警 |
| Redis 计数器泄漏 | 并发额度被耗尽却无活跃通话 | 每个 call_session 设 TTL；engine 启动时清理孤儿计数 |
| 跟进时摘要膨胀 | 历史轮数多了 prompt 超 token | scheduler 打包时只取最近 N 次或 LLM 二次压缩 |

---

## 何时算 v1 完成

最小可上线标准：
1. 单 engine 实例支持 50 路并发 8 小时不崩
2. 端到端：导入 100 条线索 → 自动外呼 → 至少 80% 通话能完成 3 轮以上对话
3. 至少 1 个 Campaign 完整跑通（音色 / 角色 / 裁判 / 润色 / 转人工 / 回调）
4. 后台 UI 能完成全部管理操作，不需要直接改 DB
5. 通话录音、transcript、提取字段、回调日志四类数据完整可查
