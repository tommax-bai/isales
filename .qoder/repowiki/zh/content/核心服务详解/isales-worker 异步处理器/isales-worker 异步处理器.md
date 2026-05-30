# isales-worker 异步处理器

<cite>
**本文档引用的文件**
- [README.md](file://README.md)
- [IMPLEMENTATION_PLAN.md](file://IMPLEMENTATION_PLAN.md)
- [design.md](file://openspec/changes/archive/2026-05-06-impl-worker/design.md)
- [proposal.md](file://openspec/changes/archive/2026-05-06-impl-worker/proposal.md)
- [tasks.md](file://openspec/changes/archive/2026-05-06-impl-worker/tasks.md)
- [webhook-callback 规范.md](file://openspec/changes/archive/2026-05-06-impl-worker/specs/webhook-callback/spec.md)
- [retry-followup 规范.md](file://openspec/changes/archive/2026-05-06-impl-scheduler/specs/retry-followup/spec.md)
- [worker.env.example](file://deploy/cloud/env/worker.env.example)
- [isales-worker.service](file://deploy/cloud/systemd/isales-worker.service)
- [check_env_consistency.py](file://deploy/linux/scripts/check_env_consistency.py)
</cite>

## 目录
1. [简介](#简介)
2. [项目结构](#项目结构)
3. [核心组件](#核心组件)
4. [架构概览](#架构概览)
5. [详细组件分析](#详细组件分析)
6. [依赖关系分析](#依赖关系分析)
7. [性能考虑](#性能考虑)
8. [故障排除指南](#故障排除指南)
9. [结论](#结论)

## 简介

isales-worker 是 iSales 语音外呼系统中的异步处理器，负责在通话结束后执行后处理任务。该系统采用 asyncio 架构，使用 Redis 作为消息队列，实现了完整的异步任务处理流水线。

### 系统目标

- **异步后处理**：消费 `engine:worker:call-ended` 队列中的通话结束事件
- **任务串行化**：按 `summarize_call → process_callbacks → update_lead_state` 顺序执行
- **回调通知**：支持 JsonLogic 触发条件、Jinja2 模板渲染、HMAC-SHA256 签名的 Webhook 回调
- **状态管理**：根据通话结果更新线索状态，支持重试和跟进策略
- **监控告警**：提供指标聚合和告警机制

## 项目结构

基于 OpenSpec 规范，isales-worker 采用模块化设计，包含以下核心模块：

```mermaid
graph TB
subgraph "核心模块"
A[main.py<br/>主入口]
B[settings.py<br/>配置管理]
C[db.py<br/>数据库连接]
D[redis_client.py<br/>Redis 客户端]
end
subgraph "任务处理"
E[callend.py<br/>CallEnded 消费]
F[summarize.py<br/>摘要生成]
G[callbacks.py<br/>回调处理]
H[lead_state.py<br/>状态管理]
I[retry_loop.py<br/>重试调度器]
J[metrics.py<br/>指标聚合]
end
subgraph "LLM 提供商"
K[llm/base.py<br/>抽象接口]
L[llm/mock.py<br/>Mock 实现]
end
subgraph "工具脚本"
M[fake_call_end.py<br/>测试注入]
end
A --> E
A --> I
A --> J
E --> F
E --> G
E --> H
F --> K
K --> L
```

**图表来源**
- [tasks.md:16-13](file://openspec/changes/archive/2026-05-06-impl-worker/tasks.md#L16-L13)

**章节来源**
- [tasks.md:4-14](file://openspec/changes/archive/2026-05-06-impl-worker/tasks.md#L4-L14)
- [README.md:1-14](file://README.md#L1-L14)

## 核心组件

### 1. CallEnded 消费器

CallEnded 消费器是系统的核心入口，负责从 Redis 队列中消费通话结束事件。

**主要功能**：
- 使用 `BLPOP` 阻塞式监听 `engine:worker:call-ended` 队列
- 反序列化 CallEnded 消息，支持多种 schema 版本
- 单条消息处理完整链路：summarize → callbacks → lead state 更新
- 错误处理和死信队列机制

**章节来源**
- [tasks.md:16-22](file://openspec/changes/archive/2026-05-06-impl-worker/tasks.md#L16-L22)
- [design.md:37-56](file://openspec/changes/archive/2026-05-06-impl-worker/design.md#L37-L56)

### 2. 摘要生成器 (summarize_call)

摘要生成器负责将通话记录转换为结构化摘要信息。

**核心特性**：
- 支持 Mock LLM Provider 和真实 LLM Provider
- 从 transcript 中提取用户语音和机器人语音内容
- 生成摘要文本和结构化提取字段
- 唯一性约束防止重复摘要

**章节来源**
- [tasks.md:24-29](file://openspec/changes/archive/2026-05-06-impl-worker/tasks.md#L24-L29)
- [design.md:57-64](file://openspec/changes/archive/2026-05-06-impl-worker/design.md#L57-L64)

### 3. 回调处理器 (process_callbacks)

回调处理器实现完整的 Webhook 回调机制。

**功能特性**：
- JsonLogic 触发条件评估
- Jinja2 沙箱模板渲染
- HMAC-SHA256 签名机制
- 指数退避重试策略
- 失败状态分类和处理

**章节来源**
- [tasks.md:31-41](file://openspec/changes/archive/2026-05-06-impl-worker/tasks.md#L31-L41)
- [design.md:66-105](file://openspec/changes/archive/2026-05-06-impl-worker/design.md#L66-L105)

### 4. 线索状态管理器 (update_lead_state)

状态管理器根据通话结果更新线索状态。

**决策矩阵**：
- 重试状态：`retrying`（达到最大重试次数后转 `failed`）
- 成功状态：`completed`（目标达成）
- 跟进状态：`following_up`（目标未达成但允许跟进）
- 终止状态：`failed`、`transferred`、`do_not_call`、`follow_up_exhausted`

**章节来源**
- [tasks.md:51-61](file://openspec/changes/archive/2026-05-06-impl-worker/tasks.md#L51-L61)
- [design.md:106-129](file://openspec/changes/archive/2026-05-06-impl-worker/design.md#L106-L129)

### 5. 重试调度器 (retry_loop)

独立的后台任务，负责处理回调重试。

**工作原理**：
- 每 60 秒扫描 `callback_log` 表中状态为 `pending_retry` 的记录
- 按 `next_retry_at` 时间排序处理
- 复用原始请求体，避免上下文漂移
- 支持最大重试次数限制

**章节来源**
- [tasks.md:42-49](file://openspec/changes/archive/2026-05-06-impl-worker/tasks.md#L42-L49)
- [design.md:98-105](file://openspec/changes/archive/2026-05-06-impl-worker/design.md#L98-L105)

### 6. 指标聚合器 (aggregate_metrics)

定时任务，负责收集和聚合系统指标。

**聚合内容**：
- 7 天内的接通率
- 目标达成率  
- 平均通话时长
- 写入 Redis Hash 结构

**章节来源**
- [tasks.md:62-68](file://openspec/changes/archive/2026-05-06-impl-worker/tasks.md#L62-L68)
- [design.md:137-142](file://openspec/changes/archive/2026-05-06-impl-worker/design.md#L137-L142)

## 架构概览

```mermaid
sequenceDiagram
participant Engine as 引擎服务
participant Redis as Redis 队列
participant Worker as Worker 进程
participant DB as 数据库
participant Callback as 回调服务
Engine->>Redis : LPUSH engine : worker : call-ended
Worker->>Redis : BLPOP engine : worker : call-ended
Redis-->>Worker : CallEnded 消息
Worker->>DB : 读取 call_record
Worker->>Worker : summarize_call()
Worker->>DB : 写入 call_summary
Worker->>Worker : process_callbacks()
Worker->>DB : 写入 callback_log
Worker->>Callback : HTTP POST 回调
Worker->>Worker : update_lead_state()
Worker->>DB : 更新 lead 状态
Note over Worker,DB : 事务性分离：<br/>回调日志提交后<br/>再更新线索状态
```

**图表来源**
- [proposal.md:12-16](file://openspec/changes/archive/2026-05-06-impl-worker/proposal.md#L12-L16)
- [design.md:131-136](file://openspec/changes/archive/2026-05-06-impl-worker/design.md#L131-L136)

## 详细组件分析

### CallEnded 消费器详细流程

```mermaid
flowchart TD
Start([开始消费]) --> BLPOP["BLPOP 等待消息<br/>超时=1秒"]
BLPOP --> HasMsg{"有消息吗？"}
HasMsg --> |否| BLPOP
HasMsg --> |是| Deserialize["反序列化 CallEnded<br/>检查 schema_version"]
Deserialize --> VersionOK{"schema_version 支持？"}
VersionOK --> |否| DLQ["LPUSH worker:dlq<br/>记录警告日志"]
VersionOK --> |是| FetchRecord["获取 call_record"]
FetchRecord --> RecordExists{"call_record 存在？"}
RecordExists --> |否| LogError["记录错误日志<br/>放弃处理"]
RecordExists --> |是| Summarize["summarize_call()"]
Summarize --> SummarizeOK{"摘要生成成功？"}
SummarizeOK --> |否| Continue["继续后续步骤<br/>使用空摘要"]
SummarizeOK --> |是| Continue
Continue --> Callbacks["process_callbacks()"]
Callbacks --> LeadState["update_lead_state()"]
LeadState --> Complete([处理完成])
DLQ --> Complete
LogError --> Complete
Continue --> Complete
```

**图表来源**
- [tasks.md:18-22](file://openspec/changes/archive/2026-05-06-impl-worker/tasks.md#L18-L22)
- [design.md:46-56](file://openspec/changes/archive/2026-05-06-impl-worker/design.md#L46-L56)

**章节来源**
- [tasks.md:16-22](file://openspec/changes/archive/2026-05-06-impl-worker/tasks.md#L16-L22)

### 回调处理完整流程

```mermaid
flowchart TD
Start([开始回调处理]) --> GetConfigs["获取启用的 callback_config"]
GetConfigs --> Parallel["并发处理每个配置<br/>asyncio.gather"]
subgraph "单个回调配置处理"
EvalTrigger["评估 JsonLogic 触发条件"]
TriggerOK{"触发条件满足？"}
TriggerOK --> |否| Skip["跳过此配置<br/>不写入日志"]
TriggerOK --> |是| InsertLog["插入 callback_log<br/>状态=pending"]
InsertLog --> Render["Jinja2 沙箱渲染<br/>StrictUndefined"]
Render --> RenderOK{"渲染成功？"}
RenderOK --> |否| FailedRender["状态=failed_render<br/>记录错误信息"]
RenderOK --> |是| Sign["HMAC-SHA256 签名<br/>添加时间戳"]
Sign --> HTTP["HTTP 请求<br/>超时配置"]
HTTP --> Status{"HTTP 状态"}
Status --> |2xx| Success["状态=success"]
Status --> |4xx| Failed4xx["状态=failed_http_4xx<br/>不重试"]
Status --> |5xx/超时/网络错误| PendingRetry["状态=pending_retry<br/>增加 retry_count"]
PendingRetry --> RetryCheck{"达到最大重试次数？"}
RetryCheck --> |是| Exhausted["状态=exhausted"]
RetryCheck --> |否| Schedule["设置 next_retry_at<br/>等待重试调度器"]
end
Skip --> NextConfig["处理下一个配置"]
FailedRender --> NextConfig
Success --> NextConfig
Failed4xx --> NextConfig
Exhausted --> NextConfig
Schedule --> NextConfig
NextConfig --> AllDone{"所有配置处理完毕？"}
AllDone --> |否| Parallel
AllDone --> |是| Complete([完成])
```

**图表来源**
- [tasks.md:31-41](file://openspec/changes/archive/2026-05-06-impl-worker/tasks.md#L31-L41)
- [webhook-callback 规范.md:3-36](file://openspec/changes/archive/2026-05-06-impl-worker/specs/webhook-callback/spec.md#L3-L36)

**章节来源**
- [tasks.md:31-41](file://openspec/changes/archive/2026-05-06-impl-worker/tasks.md#L31-L41)

### 线索状态决策矩阵

```mermaid
flowchart TD
Start([开始状态决策]) --> CheckDoNotCall{"是否勿打？<br/>goal_type='do_not_call'<br/>或 transcript 含 do_not_call_marked"}
CheckDoNotCall --> |是| DoNotCall["状态=do_not_call<br/>next_call_at=NULL<br/>清理未来调度"]
CheckDoNotCall --> |否| CheckHandoff{"是否转人工？<br/>hangup_cause=marked_for_handoff"}
CheckHandoff --> |是| Transferred["状态=transferred"]
CheckHandoff --> |否| CheckHangupCause{"检查挂断原因"}
subgraph "挂断原因分类"
CheckHangupCause --> NoAnswer["no_answer<br/>user_busy<br/>network_out_of_order<br/>temporary_failure"]
NoAnswer --> RetryCheck{"retry_count+1 < retry_max_count？"}
RetryCheck --> |是| Retrying["状态=retrying<br/>retry_count++<br/>计算 next_call_at"]
RetryCheck --> |否| Failed1["状态=failed"]
CheckHangupCause --> Rejected["call_rejected"]
Rejected --> Failed2["状态=failed"]
CheckHangupCause --> NormalClearing["normal_clearing<br/>wrap_up_completed<br/>silence_max_reached<br/>user_hangup"]
NormalClearing --> GoalCheck{"goal_achieved？"}
GoalCheck --> |是| Completed["状态=completed"]
GoalCheck --> |否| FollowUpCheck{"follow_up_count+1 < follow_up_max_count？"}
FollowUpCheck --> |是| FollowingUp["状态=following_up<br/>follow_up_count++<br/>计算 next_call_at"]
FollowUpCheck --> |否| FollowUpExhausted["状态=follow_up_exhausted"]
end
DoNotCall --> End([结束])
Transferred --> End
Retrying --> End
Failed1 --> End
Failed2 --> End
Completed --> End
FollowingUp --> End
FollowUpExhausted --> End
```

**图表来源**
- [design.md:114-129](file://openspec/changes/archive/2026-05-06-impl-worker/design.md#L114-L129)
- [retry-followup 规范.md:34-51](file://openspec/changes/archive/2026-05-06-impl-scheduler/specs/retry-followup/spec.md#L34-L51)

**章节来源**
- [design.md:106-129](file://openspec/changes/archive/2026-05-06-impl-worker/design.md#L106-L129)

## 依赖关系分析

### 外部依赖

```mermaid
graph TB
subgraph "Python 依赖"
A[isales-common >= 0.1.2<br/>Pydantic 2 / SQLAlchemy 2]
B[sqlalchemy[asyncio]<br/>asyncpg]
C[redis]
D[httpx]
E[jinja2<br/>json-logic-py]
F[cryptography]
end
subgraph "系统依赖"
G[PostgreSQL 15+]
H[Redis 7+]
I[Python 3.11+]
end
Worker --> A
Worker --> B
Worker --> C
Worker --> D
Worker --> E
Worker --> F
A --> G
A --> H
Worker --> I
```

**图表来源**
- [tasks.md:7-8](file://openspec/changes/archive/2026-05-06-impl-worker/tasks.md#L7-L8)

### 配置依赖关系

| 环境变量 | 用途 | 依赖服务 | 默认值 |
|---------|------|----------|--------|
| `ISALES_DATABASE_URL` | 数据库连接 | PostgreSQL | - |
| `ISALES_REDIS_URL` | Redis 连接 | Redis | - |
| `ISALES_FERNET_KEY` | 加密密钥 | 所有服务共享 | - |
| `ISALES_WORKER_LLM_PROVIDER` | LLM 提供商类型 | LLM Provider | `mock` |
| `ISALES_WEBHOOK_DEFAULT_TIMEOUT_SECONDS` | 回调超时 | HTTP 请求 | `10` |
| `ISALES_WORKER_RETRY_TICK_INTERVAL` | 重试轮询间隔 | 重试调度器 | `60` |
| `TZ` | 时区设置 | 所有时间相关操作 | `Asia/Shanghai` |

**章节来源**
- [tasks.md:11](file://openspec/changes/archive/2026-05-06-impl-worker/tasks.md#L11)
- [worker.env.example:6-28](file://deploy/cloud/env/worker.env.example#L6-L28)

## 性能考虑

### 并发处理策略

1. **单实例部署**：v1 采用单实例部署，避免分布式协调复杂度
2. **异步非阻塞**：所有 I/O 操作使用 asyncio，提高并发效率
3. **回调并行化**：单条消息内多个回调配置使用 `asyncio.gather` 并行处理

### 资源管理

```mermaid
flowchart TD
Start([任务开始]) --> AcquireDB["获取数据库连接<br/>使用连接池"]
AcquireDB --> AcquireRedis["获取 Redis 连接"]
subgraph "任务执行"
Summarize["摘要生成"]
Callbacks["回调处理"]
LeadState["状态更新"]
end
Summarize --> ReleaseRedis["释放 Redis 连接"]
Callbacks --> ReleaseDB1["释放数据库连接"]
LeadState --> ReleaseAll["释放所有连接"]
AcquireRedis --> Summarize
AcquireDB --> Summarize
ReleaseAll --> End([任务结束])
```

**图表来源**
- [design.md:37-44](file://openspec/changes/archive/2026-05-06-impl-worker/design.md#L37-L44)

### 监控指标

系统提供以下监控指标：

| 指标类型 | 指标名称 | 描述 |
|---------|----------|------|
| 计数器 | `call_processed_total` | 处理的通话总数 |
| 计数器 | `callback_success_total` | 成功回调数量 |
| 计数器 | `callback_failed_total` | 失败回调数量 |
| 计数器 | `lead_state_updated_total` | 线索状态更新数量 |
| 计时器 | `callback_duration_seconds` | 回调处理耗时 |
| 计数器 | `error_count_total` | 错误发生次数 |

## 故障排除指南

### 常见问题诊断

#### 1. 消息消费问题

**症状**：Worker 不消费队列消息
**排查步骤**：
1. 检查 Redis 服务状态：`redis-cli ping`
2. 验证队列是否存在：`redis-cli LLEN engine:worker:call-ended`
3. 检查 Worker 日志：`journalctl -u isales-worker -f`

**章节来源**
- [tasks.md:18](file://openspec/changes/archive/2026-05-06-impl-worker/tasks.md#L18)

#### 2. 回调失败问题

**症状**：回调请求失败或超时
**排查步骤**：
1. 检查 callback_log 表状态
2. 验证目标服务可达性
3. 查看重试调度器日志
4. 检查网络超时配置

**章节来源**
- [tasks.md:42-49](file://openspec/changes/archive/2026-05-06-impl-worker/tasks.md#L42-L49)

#### 3. 线索状态更新冲突

**症状**：UPDATE lead 语句返回 0 行受影响
**可能原因**：
- Scheduler 还未将状态设置为 'calling'
- 其他 Worker 已经更新了状态
- 线索已被手动修改

**解决方案**：
- 检查状态守卫条件
- 查看日志中的 WARN 信息
- 确认业务流程正确性

**章节来源**
- [design.md:106-112](file://openspec/changes/archive/2026-05-06-impl-worker/design.md#L106-L112)

### 部署和配置检查

```mermaid
flowchart TD
Start([部署检查]) --> EnvConsistency["检查环境变量一致性"]
EnvConsistency --> CheckEnv["验证 worker.env 配置"]
CheckEnv --> DBTest["测试数据库连接"]
DBTest --> RedisTest["测试 Redis 连接"]
RedisTest --> ServiceTest["测试 systemd 服务"]
ServiceTest --> MetricsTest["验证指标收集"]
EnvConsistency --> EnvConsistency
CheckEnv --> CheckEnv
DBTest --> DBTest
RedisTest --> RedisTest
ServiceTest --> ServiceTest
MetricsTest --> MetricsTest
EnvConsistency --> Done([检查完成])
CheckEnv --> Done
DBTest --> Done
RedisTest --> Done
ServiceTest --> Done
MetricsTest --> Done
```

**图表来源**
- [check_env_consistency.py:17](file://deploy/linux/scripts/check_env_consistency.py#L17)
- [check_env_consistency.py:38](file://deploy/linux/scripts/check_env_consistency.py#L38)

**章节来源**
- [check_env_consistency.py:17](file://deploy/linux/scripts/check_env_consistency.py#L17)
- [check_env_consistency.py:38](file://deploy/linux/scripts/check_env_consistency.py#L38)

## 结论

isales-worker 异步处理器是一个设计精良的后台处理系统，具有以下特点：

### 技术优势

1. **架构简洁**：采用 asyncio + Redis 的轻量级设计，避免了复杂的分布式协调
2. **任务串行化**：确保业务逻辑的正确性和一致性
3. **完善的错误处理**：包含重试机制、死信队列和详细的日志记录
4. **监控完备**：提供指标聚合和告警机制

### 业务价值

1. **自动化程度高**：从通话结束到状态更新的全流程自动化
2. **扩展性强**：支持多种 LLM Provider 和回调配置
3. **可靠性保障**：通过指数退避和重试机制确保任务完成
4. **运维友好**：提供丰富的监控指标和故障诊断能力

### 发展建议

1. **性能优化**：随着业务增长，可考虑多实例部署和任务分片
2. **监控增强**：增加更细粒度的指标和告警规则
3. **配置管理**：引入配置中心支持动态调整参数
4. **可观测性**：增加分布式追踪和性能分析工具

该系统为 iSales 语音外呼平台提供了坚实的异步处理基础，为后续的功能扩展和性能优化奠定了良好的技术基础。