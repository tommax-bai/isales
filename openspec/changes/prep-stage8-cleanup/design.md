## Context

5 个独立小问题集中收掉。每个都不大，但散落在 4 个仓里。设计的目标是让一次 PR 即可同时改 4 个仓但 review 时仍清楚——按问题分组而不是按仓分组。

## Goals / Non-Goals

**Goals:**

- 让 `pytest` / `make test-all` 在 main 分支无 flake 通过
- impl 与 device-hardware spec § engine ↔ modem-controller IPC 协议 完全对齐（只 session_id，无 call_id 字段）
- 跨仓测试一键跑
- impl-web-polish 5 个 DEFERRED 里的"小事"做掉，剩下大件保持 DEFERRED

**Non-Goals:**

- 重写 IPC 帧格式（length-prefix 留 v2）
- 重写 web 测试架构（Playwright e2e 留 v2）
- 真硬件相关
- 任何 spec requirement 改动

## Decisions

### 1. pump task 跟踪：在 Connection 上挂 cancel_event

- **选择**：每个 `Connection` 暴露 `cancel_event: asyncio.Event`，pump 协程在 `_set_device_status` / `conn.send` 前 check；IPCServer `_on_connect` finally 块里 set 它。`build_handlers` 不变签名（`Mapping[str, Handler]` 仍然返回）
- **理由**：
  - 改动局限在 ipc_server + handlers 两个文件
  - 不需要把 pump task 集合穿到 IPCServer，handlers 自治
  - cancel_event 是 asyncio 标准模式，比手工管 task list 易理解
- **替代**：
  - `build_handlers` 多返回 `pump_tasks: set[Task]` → 接口扩张，每个调用方都得改
  - `asyncio.gather(*pump_tasks, return_exceptions=True)` on stop → 更激进，但要管 task 的 set 增减
  - 用 `weakref.WeakSet[Task]` → 还是需要侵入式的 task 注册

### 2. session_id 字段统一：caller 没传时用 modem UUID 兜底

- **选择**：`handle_dial` 永远把 ack/events 的 `session_id` 字段填上——caller 传了用 caller 的；没传就用 MockATClient 生成的 UUID（即原来的 `call_id`）作为 session_id
- **理由**：
  - 对外接口纯净（只有 session_id 一个 key）
  - 仍然保持"caller 不传 session_id 也能用"的 backward-compat（spec § engine ↔ modem-controller IPC 协议 没规约 session_id 必须由 caller 提供）
  - `handle_hangup` 同理：caller 传的 session_id（在 PR #5 已支持）；如果没传 session_id 但传 `call_id`（旧 client），honor 旧 `call_id` 字段触发 ATClient.hangup 但 ack 仍只回 session_id（用旧 call_id 字符串作为兜底）
- **替代**：
  - 严格只接 session_id，不再容忍旧 call_id → BREAKING；engine RealTelephonyClient 自己用 session_id，不影响；唯一可能影响是手工调试脚本，可以忽略
  - 选了上一条的弱化版：`hangup` 仍兼容旧 call_id 字段（handlers 层），但事件帧只 emit session_id

### 3. test 升级：sock-pair fixture vs 临时文件

- **选择**：保留临时文件方案（`tempfile.gettempdir() + uuid`），因为现在 macOS path 长度问题已被处理且测试稳定。**不升级到 sock-pair**——边际收益低且会强制改一堆 fixture
- **理由**：测试本身没问题；问题是 pump task 泄漏，由决策 §1 解决。fixture 重构是单独价值，本 change 不做
- **替代**：sock-pair fixture（in-memory）→ 重写量大，IPC server 不需要文件路径——但 stage-2 现有 fixture 已经稳定，不动

### 4. 跨仓 test orchestrator：bash + 各仓 venv

- **选择**：`scripts/test_all.sh` 顺序跑（不并行），每个仓激活自己的 `.venv` 跑 `pytest -q`；isales-web 跑 `npx vitest run`。失败的仓汇总到 summary 但 script 仍跑完所有仓
- **理由**：
  - 顺序跑：debug 时输出整齐；并行跑要管 lock + 输出交错
  - 各仓 .venv 已存在（开发模式装 -e），不重复 pip install
  - script 跑完所有仓——一次性看完所有失败，不是发现一个就 abort
- **替代**：
  - 并行 → v2，需要先把日志着色 / 仓名前缀加进每行
  - tox / nox → 重；本项目没有跨仓 test orchestration history，新引入工具链不值
  - 一个 docker-compose 起所有仓 → stage 8 候选

### 5. CallList 分页对齐 LeadList

- **选择**：复制 LeadList 的 page/page_size pinia 风格 + el-pagination 模板
- **理由**：UI 一致性是 v1 完成标准 #4 的隐含要求；用户切换 list 页时不应该体验差异

### 6. README CI badge：单仓 isales-web 加，主仓不加

- **选择**：只在 isales-web/README 顶部加 GitHub Actions badge；isales 主仓 README 不动
- **理由**：主仓没 GitHub Actions（它是个 spec / docs 仓）；其他业务仓的 README 在归档时会逐个加，本 change 只补 web

## Risks / Trade-offs

| 风险 | 缓解 |
|---|---|
| pump task 跟踪改动可能引入新 race | 测试覆盖：原有 `test_modem_dial::test_dial_emits_connected_then_hangup_and_flips_status` 是黄金案例，确保它先跑过；再跑 full-suite + 重复 5 次 |
| 删 `call_id` 字段如果有手工调试脚本依赖 | repo grep "call_id" 在 isales-engine / isales-web 里没有手工脚本依赖；spec / docs 引用的是 session_id |
| `make test-all` 在 CI 里跑可能超时 | script 加 per-repo timeout（默认 5 分钟）；超时仓单独标 fail |
| isales-web vitest 在 macOS 上偶发 jsdom warning | 已知 (impl-web-polish 时有 stderr 噪音但不 fail)；script grep stderr 不 fail，只 fail on exit code |
| 跨仓 venv 路径假设 | script 检测 `.venv/bin/python` 存在，若没有则报错并提示运行 `pip install -e .[dev]` |
| CallList el-pagination 加完后样式与 LeadList 偶有差异 | 直接复制 LeadList 的 .pagination CSS 块，保证一致 |

## Migration Plan

不适用——纯 cleanup，不动 schema / 数据 / 部署形态。

部署：

1. 各仓 git pull
2. 跑 `make test-all` 验证
3. 无服务重启需求

回滚：git revert，无副作用。

## Open Questions

- 是否值得在本 change 顺手把 `device-hardware` spec § engine ↔ modem-controller IPC 协议 的"双向独立流"补一个 explicit Scenario 说明 session_id 是 caller-provided?
  - 决策：不做。spec 已经够清楚，本 change 是 impl 对齐，不是 spec 改
- `make test-all` 是否要包含 isales 主仓自身（如有 lint/fmt check）?
  - 决策：不做。主仓没 pytest，只有 OpenSpec 文档；`openspec validate --specs` 是另一条
- isales-web tests/setup.ts 删掉后 vitest 是否抱怨?
  - 决策：检查 vitest config 是否还引用；引用就一并删

# 实施 PR 拆分

按问题域 1-5 拆 5 个 PR：

- PR #1: telephony pump task cancellation（+ 跑通 full-suite 5 次确认 flake 修了）
- PR #2: telephony IPC 协议字段统一为 session_id（删 call_id 字段；engine RealTelephonyClient 同步）
- PR #3: 主仓 scripts/test_all.sh + Makefile
- PR #4: isales-web CallList pagination
- PR #5: isales-web README CI badge + 删 tests/setup.ts
- PR #6: 收尾——`make test-all` 全绿；主仓 commit；archive
