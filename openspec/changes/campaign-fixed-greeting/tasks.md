## 1. isales-common: Campaign 模型加 greeting 字段

- [ ] 1.1 编辑 `isales-common/isales_common/models/campaign.py`: 在 `Campaign` 类内（建议放在 wrap_up_max_seconds / wrap_up_closing_phrases 附近、保留按业务功能分组）加 `greeting: Mapped[str | None] = mapped_column(Text, nullable=True)`
- [ ] 1.2 import `Text` from `sqlalchemy` 如尚未存在
- [ ] 1.3 audit `isales-common/isales_common/schemas/campaign.py`（如有 Pydantic schema 文件）：CampaignRead / CampaignCreate / CampaignUpdate 视具体 schema 加 `greeting: str | None = None`
- [ ] 1.4 isales-common 跑 lint / type-check / 单测确认无 break

## 2. 部署侧: alembic migration

- [ ] 2.1 在 isales-common（或 deploy）仓 alembic migrations 目录加新 migration 文件 `<YYYYMMDD>_<seq>_add_campaign_greeting.py`：upgrade 跑 `op.add_column('campaign', sa.Column('greeting', sa.Text(), nullable=True))`；downgrade 跑 `op.drop_column('campaign', 'greeting')`
- [ ] 2.2 命名按现有 alembic 风格（参考 `provider_credential` 那个 migration 命名约定）
- [ ] 2.3 本地（mac dev）跑 `alembic upgrade head` 验证 migration 无 SQL 错误（如果有本地 PG）

## 3. isales-engine: 删 _FIXED_GREETINGS hack + 读 campaign.greeting

<!-- 84c5db8 isales-engine commit "experiment(judge-context-and-greeting)" 里
     的 _FIXED_GREETINGS 字典 hack 由本 change 替换 -->

- [ ] 3.1 编辑 `isales-engine/isales_engine/runtime_config.py`: 删 `_FIXED_GREETINGS: dict[int, str] = {1: "..."}` 字典定义 + 注释
- [ ] 3.2 改 `fixed_greeting: str | None = _FIXED_GREETINGS.get(campaign.id)` 为 `fixed_greeting: str | None = campaign.greeting`
- [ ] 3.3 isales-engine 跑 `make test-all PYTEST_ARGS="-k runtime_config or campaign or greeting"` 全绿
- [ ] 3.4 跑全套 `cd ~/codes/isales-engine && .venv/bin/python -m pytest -q` 确认无新回归（5 个 pre-existing TTS volcengine 失败跟本 change 无关，可忽略）

## 4. isales-api: campaign router schema audit

- [ ] 4.1 audit `isales-api/isales_api/routers/campaigns.py`（路径 audit 时确认）+ schema 模块：campaign POST/PUT body 是否能透传 `greeting` 字段
- [ ] 4.2 如果 schema 严格列字段：加 `greeting: str | None = None` 到 Create/Update body
- [ ] 4.3 如果 schema 用 `model_dump(exclude_unset=True)` 透传：无需改动，但 audit 验证 isales-common Pydantic schema 已含 greeting (任务 1.3)
- [ ] 4.4 isales-api 跑测试套确认无 break

## 5. isales-web: campaign 编辑表单加 greeting 输入

- [ ] 5.1 audit 当前 campaign 编辑 view 实施位置：客户面 `views/Campaigns/CampaignDetail.vue` 或运营面 `views/Operations/Campaigns/<*>.vue`
- [ ] 5.2 在选定 view 的编辑表单（推荐放在跟 default_replies / wrap_up_closing_phrases 等话术相关字段附近）加 `<el-form-item label="开场白文案">`
- [ ] 5.3 控件用 `<el-input type="textarea" :rows="3" v-model="form.greeting" placeholder="留空则由 LLM 生成开场白" />`，跟 `STYLE_GUIDE.md` 视觉一致
- [ ] 5.4 form data 初始化时 `greeting: campaign.greeting ?? ''`（NULL 显示成空）；保存前 `greeting: form.greeting?.trim() || null`（空串 normalize 为 null）
- [ ] 5.5 跑 isales-web `npm run lint && npm run build` 确认无构建 break

## 6. 部署 ECS（顺序敏感）

<!-- 顺序锁死在 design.md § 决策 3。倒序会让 campaign id=1 那一瞬走 LLM
     路径，跟期望行为不一致。 -->

- [ ] 6.1 备份 ECS PG `campaign` 表 — `ssh -i ~/codes/isales-4.pem root@121.89.85.150 'sudo -u postgres pg_dump -t campaign isales > /tmp/campaign-backup-$(date +%Y%m%d-%H%M%S).sql'`
- [ ] 6.2 SCP 新 alembic migration 文件到 ECS（按 `[[feedback_ecs_deploy_scp]]` 规则）
- [ ] 6.3 在 ECS 上跑 `alembic upgrade head`，验证 `campaign` 表加了 `greeting TEXT NULL` 列：`\d campaign` 确认
- [ ] 6.4 ECS PG SQL UPDATE：`UPDATE campaign SET greeting = '您好，我是智联招聘的小雨，请问您现在方便接电话吗？' WHERE id = 1;`（保持当前 hack 行为）
- [ ] 6.5 SCP 新 `runtime_config.py`（hack 删除版本）到 ECS `/opt/isales/current/isales-engine/isales_engine/runtime_config.py`
- [ ] 6.6 `ssh ... systemctl restart isales-engine`
- [ ] 6.7 ECS journalctl 验证 `isales_engine_started` + `credentials_loaded count=5` 无 import error

## 7. 联合验收

- [ ] 7.1 mac dev DingRTC 真拨号（按 memory `project_macos_dev_path` 的一行启动命令；JWT + RTC env 用 `~/.isales/edge-dev.jwt` + `~/.isales/rtc.env`，详见 session 2026-05-29 流程）
- [ ] 7.2 拨通后听 greeting，应跟当前一致：「您好，我是智联招聘的小雨，请问您现在方便接电话吗？」
- [ ] 7.3 ECS engine log grep TTS first_byte，应见 `text_len=25` first_byte
- [ ] 7.4 ECS 端验证一次 isales-web 编辑流程：改 greeting 为略不同的文案（如加个"哈哈"在末尾），保存；下一通 dial 听到的 greeting 应是新文案，无需 engine 重启

## 8. Archive 准备

- [ ] 8.1 跑 `openspec validate campaign-fixed-greeting --strict` 全绿
- [ ] 8.2 isales-common 仓 commit + push（model 改动）
- [ ] 8.3 isales-engine 仓 commit + push（hack 删除）
- [ ] 8.4 isales-web 仓 commit + push（表单字段）
- [ ] 8.5 isales-api 仓（如改了）commit + push
- [ ] 8.6 部署侧 alembic 仓 commit + push
- [ ] 8.7 meta-repo `~/codes/isales` commit 本 change 全 4 artifact + tasks.md 进度回写
- [ ] 8.8 meta-repo push origin main
- [ ] 8.9 跑 `/opsx:archive campaign-fixed-greeting`，合并 spec delta（data-model + web-admin-ui）到对应 `openspec/specs/<capability>/spec.md`，移动 change 目录到 `openspec/changes/archive/YYYY-MM-DD-campaign-fixed-greeting/`
- [ ] 8.10 archive 后 commit + push meta-repo
