# iSales

iSales 主仓——OpenSpec specs / 实施计划 / 跨仓工具脚本。代码本身分散在 7 个
sibling 仓里：

```
isales-common      # Pydantic / SQLAlchemy 模型 + 跨仓共享 schema
isales-api         # FastAPI HTTP 后台（campaigns / leads / calls / ...）
isales-telephony   # /devices /sim-cards + modem-controller 守护进程
isales-scheduler   # 调度器（campaign 启停 / 拨号队列）
isales-worker      # 后台 worker（callback / recording upload / watchdog）
isales-engine      # 实时通话引擎（事件/角色驱动 gate-first + 双 LLM 流式管线 + cloud-edge gRPC server）
isales-web         # Vue 3 管理面
```

## Production deployment

v1.0 形态是**云-边拆分**（取代早期"单主机 7 服务"模型，详见 `openspec/specs/architecture/spec.md`）：

- **云端**（阿里云 ECS）—— `isales-api` / `isales-engine` / `isales-scheduler` /
  `isales-worker` / `nginx-isales-web` 五个 systemd unit；PostgreSQL + Redis 走阿里云托管；
  媒体面用 DingRTC PaaS，控制面是 cloud-edge gRPC bidi（bearer token）。
  上线 / 调试 / 备份见 [`deploy/RUNBOOK-cloud.md`](deploy/RUNBOOK-cloud.md)，
  **当前运行快照**（ECS IP / 版本 / vendor 路径 / 已验证项）见
  [`deploy/cloud/STATE.md`](deploy/cloud/STATE.md)。
- **边缘**（客户机房 Windows PC / Mac mini，一座席 = 一 PC + 一 USB GSM modem + 一 SIM）——
  `isales-telephony` 单进程（modem-controller + audio-bridge），不暴露公网端口。
  Windows 开发机快照见
  [`isales-telephony/deploy/edge/windows/STATE.md`](../isales-telephony/deploy/edge/windows/STATE.md)。

> **Legacy 单主机部署**（Linux + systemd / macOS 14+ Apple Silicon + launchd，全部 7 服务
> 同主机 + 直插 USB modem）仍可运行，制品在 `deploy/linux/` + `deploy/macos/`，运维见
> [`deploy/RUNBOOK.md`](deploy/RUNBOOK.md)。云-边形态落地后它不再是 v1.0 主线。

## 跨仓测试一键跑

```bash
make test-all
# 或：bash scripts/test_all.sh -k modem
```

按顺序跑每个仓的 `pytest`（isales-web 跑 vitest），最后打一行汇总：每仓
pass/fail 数 + 总耗时；任一仓失败 exit code 非零。每个仓需要先在自己的目录
里做开发模式安装（`pip install -e ".[dev]"`），web 仓需要 `npm install`。

## 校验 deploy/ 脚本与 env 一致性

```bash
make deploy-check
```

跑 `shellcheck` 校验 `deploy/linux/scripts/*.sh` + 检查 `deploy/env/*.env.example`
与各服务 README "Environment" 列表是否一致。

## 校验所有 OpenSpec 制品

```bash
make spec-validate
```

跑 `openspec validate --specs` + `openspec validate --changes`，确保仓里所有
spec 与 active change 都没有结构错误。

## OpenSpec workflow

完整的 spec / change / archive 流程见 `openspec/`。常用命令：

```bash
openspec list                                      # active changes
openspec status --change <name>                    # 单 change 进度
/opsx:propose <name>                               # 起草新 change
/opsx:apply <name>                                 # 实施
/opsx:archive <name>                               # 归档（含 spec sync）
```
