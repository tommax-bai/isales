# iSales

iSales 主仓——OpenSpec specs / 实施计划 / 跨仓工具脚本。代码本身分散在 7 个
sibling 仓里：

```
isales-common      # Pydantic / SQLAlchemy 模型 + 跨仓共享 schema
isales-api         # FastAPI HTTP 后台（campaigns / leads / calls / ...）
isales-telephony   # /devices /sim-cards + modem-controller 守护进程
isales-scheduler   # 调度器（campaign 启停 / 拨号队列）
isales-worker      # 后台 worker（callback / recording upload / watchdog）
isales-engine      # 实时通话引擎（状态机 + 三层 AI 管线）
isales-web         # Vue 3 管理面
```

## Production deployment

iSales v1 走单主机 + systemd 部署模型。完整脚本与 runbook 见
[`deploy/README.md`](deploy/README.md)。运维操作直接看 RUNBOOK：
[首次上线](deploy/RUNBOOK.md#1-first-time-deployment) ·
[日常发版](deploy/RUNBOOK.md#2-routine-deploy) ·
[回滚](deploy/RUNBOOK.md#3-rollback) ·
[备份恢复](deploy/RUNBOOK.md#4-backup-recovery-drill) ·
[故障排查](deploy/RUNBOOK.md#5-failure-cheatsheet) ·
[上线前 hard-gate](deploy/RUNBOOK.md#6-pre-launch-hard-gates)。

```bash
# 在目标主机上：
sudo bash deploy/scripts/provision.sh                      # 一次性
sudo -u isales bash deploy/scripts/install.sh v0.1.0       # 拉新 release
sudo -u isales bash deploy/scripts/migrate.sh              # alembic upgrade head
sudo bash deploy/scripts/deploy.sh <release-ts>            # 切 current + restart
```

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

跑 `shellcheck` 校验 `deploy/scripts/*.sh` + 检查 `deploy/env/*.env.example`
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
