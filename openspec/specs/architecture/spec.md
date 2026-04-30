## Purpose

定义 iSales 系统的总体架构：7 仓库划分、单主机部署模型、各服务职责边界、共享库依赖关系。本规范是顶层视图，具体功能模块的设计 SHALL 在各 capability spec 中独立定义。

## Requirements

### Requirement: 7 仓库微服务架构

iSales SHALL 拆分为 7 个独立 Git 仓库；isales-common 作为共享库被 6 个服务依赖。

#### Scenario: 仓库列表

- **WHEN** 启动新建仓库
- **THEN** 仓库集合 MUST 包含且仅包含：
  - `isales-common`（共享库，pip 包）
  - `isales-api`（管理后台 + WS 代理）
  - `isales-engine`（实时通话引擎）
  - `isales-scheduler`（线索调度）
  - `isales-worker`（异步后处理）
  - `isales-telephony`（含 telephony-api + modem-controller 两个进程）
  - `isales-web`（Vue 3 前端）

#### Scenario: 不引入 monorepo

- **WHEN** 实施
- **THEN** MUST NOT 把 7 仓库合并为 monorepo；isales-common SHALL 通过内部 PyPI 或 git 直装方式分发

### Requirement: 各仓库职责边界

每个仓库 SHALL 承担明确的职责边界，跨仓库的功能 MUST 在设计阶段拆分到具体仓库主导。

| 仓库 | 职责 | 规模 |
|---|---|---|
| isales-common | SQLAlchemy 模型 / Pydantic Schemas / Provider ABC（ASR/TTS/LLM）/ Alembic 迁移 / utils | 小 |
| isales-api | 管理后台 CRUD（Campaign/Lead/Role/Voice/Analytics/Callback）+ WS 代理 | 中 |
| isales-engine | 实时通话引擎：状态机 / AI 三层管线 / 打断/沉默/垫词 / ASR/TTS/LLM Provider 实现 / 调 modem-controller | 大 |
| isales-scheduler | 线索分发 / 时间窗口 / 重试与跟进 / 拨打前打包历史摘要 | 小 |
| isales-worker | 通话结束后的摘要 / 字段提取 / Webhook 回调 / 数据聚合 | 中 |
| isales-telephony | 两个进程：telephony-api（HTTP）+ modem-controller（守护，AT 命令 / PCM 音频 / udev） | 中 |
| isales-web | Vue 3 前端（任务/线索/角色/音色/设备/数据看板/通话监控） | 中 |

#### Scenario: 跨仓库职责重叠

- **WHEN** 引入新功能
- **THEN** 设计阶段 MUST 明确归属一个仓库；MUST NOT 把同一职责分散到多个仓库（但一个职责可能跨多仓库分阶段执行——如转人工触发由 engine、派发由 worker、查询由 api）

### Requirement: v1 单主机部署

v1 SHALL 把全部服务（engine + telephony + scheduler + worker + USB GSM modem）部署在一台服务器，匹配 ≤8 路并发目标。多主机扩展 MUST 列入 v2。

#### Scenario: 部署拓扑

- **WHEN** v1 投产
- **THEN** 7 个进程（含 telephony-api 和 modem-controller 两个 entry point）SHALL 同主机部署；USB GSM modem 直插同一主机

#### Scenario: 进程隔离

- **WHEN** 部署 v1
- **THEN** 每个服务 SHALL 独立 systemd unit；isales-common 作为依赖嵌入各进程，无独立运行进程

### Requirement: 数据存储统一

所有服务 SHALL 共享一个 PostgreSQL 实例与一个 Redis 实例。所有数据库迁移 MUST 由 isales-common/alembic 管理。

#### Scenario: 数据库共享

- **WHEN** 任何服务读写数据
- **THEN** MUST 通过 isales-common 的 SQLAlchemy 模型；MUST NOT 直接写 SQL 绕过 ORM 模型（除性能必要场景外）

#### Scenario: Redis 用途

- **WHEN** 服务间通信或缓存
- **THEN** Redis SHALL 用作：① 队列（scheduler→engine、engine→worker、api→scheduler）② Pub/Sub（api↔engine 实时控制与事件推送）③ 全局并发计数器（INCR/DECR）④ 缓存

### Requirement: isales-common 共享库

isales-common SHALL 仅包含跨服务共享的稳定接口与模型，MUST NOT 包含特定服务的业务逻辑。

#### Scenario: isales-common 内容

- **WHEN** 在 isales-common 添加新内容
- **THEN** 该内容 MUST 同时满足：① 至少被两个服务使用 ② 不绑定任何特定服务的业务流程 ③ 接口稳定（变更频率低）

#### Scenario: 不放在 isales-common 的内容

- **WHEN** 内容只服务于一个特定服务
- **THEN** MUST 放在该服务自己的仓库；不能为了"复用"过早抽到 common（避免跨仓库耦合）

### Requirement: 决策权衡

架构选型的关键权衡 SHALL 以决策记录的形式留档；任何重大调整 MUST 经过 OpenSpec change proposal 流程。

#### Scenario: 选择多仓库而非 monorepo 的原因

- **WHEN** 评估架构选型
- **THEN** 选择多仓库的理由 MUST 记录：单仓库代码量在 Claude Code 单会话上下文中难以高效迭代；isales-common 通过 pip 包分发可清晰隔离边界

## Architecture Diagram

```
┌────────────────────────────────────────────────────────────────────┐
│                          isales-web (Vue 3)                         │
└──────────────────────────────────┬─────────────────────────────────┘
                                   │ HTTP / WebSocket
                                   ▼
┌────────────────────────────────────────────────────────────────────┐
│                  isales-api (管理 API + WS 代理)                    │
└──────┬──────────────┬──────────────────┬──────────────┬────────────┘
       │              │                  │              │
       │       Redis Pub/Sub      Redis Queue           │ HTTP
       ▼              ▼                  ▼              ▼
┌────────────┐ ┌──────────────────┐ ┌────────────────┐ ┌──────────────────┐
│ scheduler  │ │     engine       │ │    worker      │ │ telephony        │
│            │ │                  │ │                │ │ (api + modem)    │
└──────┬─────┘ └────────┬─────────┘ └────────────────┘ │  ┌─────────────┐ │
       │                │                              │  │telephony-api│ │
       │                │ 本地 IPC (Unix socket)        │  └──────┬──────┘ │
       │                └──────────────────────────────►│  ┌──────▼──────┐ │
       │                                                │  │modem-       │ │
       │                                                │  │controller   │ │
       │                                                │  └──────┬──────┘ │
       │                                                └─────────│────────┘
       │                                                          ▼
       │                                                  ┌──────────────┐
       │                                                  │ USB GSM      │
       │                                                  │ Modem × ≤8   │
       │                                                  └──────────────┘
       │
       └─→ 拨号前调 telephony-api /devices/select

         ┌──────────────────────────────────┐
         │  isales-common (pip 共享库)       │
         └──────────────────────────────────┘
              ▲ 被 6 个服务共同依赖
```
