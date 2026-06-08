## 1. isales-common: Campaign 模型加 greeting 字段

- [x] 1.1 编辑 `isales-common/isales_common/models/campaign.py`: 在 `Campaign` 类内（建议放在 wrap_up_max_seconds / wrap_up_closing_phrases 附近、保留按业务功能分组）加 `greeting: Mapped[str | None] = mapped_column(Text, nullable=True)` <!-- isales-common: greeting Mapped[str|None] 加在 wrap-up 段后；commit pending -->
- [x] 1.2 import `Text` from `sqlalchemy` 如尚未存在 <!-- 加 Text 到 sqlalchemy import list -->
- [x] 1.3 audit `isales-common/isales_common/schemas/campaign.py`（如有 Pydantic schema 文件）：CampaignRead / CampaignCreate / CampaignUpdate 视具体 schema 加 `greeting: str | None = None` <!-- CampaignBase 加 greeting → CampaignCreate/CampaignRead 自动继承；CampaignUpdate 单独加 -->
- [x] 1.4 isales-common 跑 lint / type-check / 单测确认无 break <!-- 151 passed in 0.72s -->


## 2. 部署侧: alembic migration

- [x] 2.1 在 isales-common（或 deploy）仓 alembic migrations 目录加新 migration 文件 `<YYYYMMDD>_<seq>_add_campaign_greeting.py`：upgrade 跑 `op.add_column('campaign', sa.Column('greeting', sa.Text(), nullable=True))`；downgrade 跑 `op.drop_column('campaign', 'greeting')` <!-- a908d5971908_add_campaign_greeting.py 落 isales-common/alembic/versions -->
- [x] 2.2 命名按现有 alembic 风格（参考 `provider_credential` 那个 migration 命名约定）<!-- 12-char hex revision id + verb_topic 文件名，跟 a1b2c3d4e5f6 / b2c3d4e5f6a7 一致 -->
- [x] 2.3 本地（mac dev）跑 `alembic upgrade head` 验证 migration 无 SQL 错误（如果有本地 PG）<!-- local PG isales_dev: 580b817550c8 → a908d5971908; \d campaign 见 greeting text NULL -->


## 3. isales-engine: 删 _FIXED_GREETINGS hack + 读 campaign.greeting

<!-- 84c5db8 isales-engine commit "experiment(judge-context-and-greeting)" 里
     的 _FIXED_GREETINGS 字典 hack 由本 change 替换 -->

- [x] 3.1 编辑 `isales-engine/isales_engine/runtime_config.py`: 删 `_FIXED_GREETINGS: dict[int, str] = {1: "..."}` 字典定义 + 注释 <!-- hack block 整段移除 -->
- [x] 3.2 改 `fixed_greeting: str | None = _FIXED_GREETINGS.get(campaign.id)` 为 `fixed_greeting: str | None = campaign.greeting` <!-- 注释改写为 spec 引用 -->
- [x] 3.3 isales-engine 跑 `make test-all PYTEST_ARGS="-k runtime_config or campaign or greeting"` 全绿 <!-- 4 passed, 273 deselected -->
- [x] 3.4 跑全套 `cd ~/codes/isales-engine && .venv/bin/python -m pytest -q` 确认无新回归（5 个 pre-existing TTS volcengine 失败跟本 change 无关，可忽略）<!-- 272 passed + 5 pre-existing TTS volcengine fails, 无新回归 -->


## 4. isales-api: campaign router schema audit

- [x] 4.1 audit `isales-api/isales_api/routers/campaigns.py`（路径 audit 时确认）+ schema 模块：campaign POST/PUT body 是否能透传 `greeting` 字段 <!-- audit: routers/campaigns.py 用 schemas.py 的 CampaignNestedCreate(CampaignBase) + CampaignNestedUpdate(AppModel) + CampaignDetailRead(CampaignRead); update_campaign 调 payload.model_dump(exclude_unset=True, exclude={children}) + setattr 透传 -->
- [x] 4.2 如果 schema 严格列字段：加 `greeting: str | None = None` 到 Create/Update body <!-- CampaignNestedUpdate 严格列字段，已加 greeting；CampaignNestedCreate(CampaignBase) 自动继承 -->
- [x] 4.3 如果 schema 用 `model_dump(exclude_unset=True)` 透传：无需改动，但 audit 验证 isales-common Pydantic schema 已含 greeting (任务 1.3) <!-- 已含，任务 1.3 完成 -->
- [x] 4.4 isales-api 跑测试套确认无 break <!-- 102 passed -->


## 5. isales-web: campaign 编辑表单加 greeting 输入

- [x] 5.1 audit 当前 campaign 编辑 view 实施位置：客户面 `views/Campaigns/CampaignDetail.vue` 或运营面 `views/Operations/Campaigns/<*>.vue` <!-- audit: 唯一全字段编辑 view 在 views/Campaigns/CampaignEdit.vue（11-tab 左侧 nav），客户面 CampaignDetail.vue 是只读详情。Operations 视图不存在 — 都跑客户面/运营面合并路径 -->
- [x] 5.2 在选定 view 的编辑表单（推荐放在跟 default_replies / wrap_up_closing_phrases 等话术相关字段附近）加 `<el-form-item label="开场白文案">` <!-- 加在 BasicTab.vue 的 default_replies 之上（开场白时序在默认回复之前）-->
- [x] 5.3 控件用 `<el-input type="textarea" :rows="3" v-model="form.greeting" placeholder="留空则由 LLM 生成开场白" />`，跟 `STYLE_GUIDE.md` 视觉一致 <!-- 沿用 SilenceTab `silence_hangup_phrase` nullable string + v-model 直接绑定 pattern -->
- [x] 5.4 form data 初始化时 `greeting: campaign.greeting ?? ''`（NULL 显示成空）；保存前 `greeting: form.greeting?.trim() || null`（空串 normalize 为 null）<!-- normalize 放 CampaignEdit.vue buildPayload；CAMPAIGN_DEFAULTS.greeting=null；Element Plus textarea v-model 能直接吃 null -->
- [x] 5.5 跑 isales-web `npm run lint && npm run build` 确认无构建 break <!-- eslint 全绿 + vite build 4.81s 成功 -->


## 6. 部署 ECS（顺序敏感）

<!-- 顺序锁死在 design.md § 决策 3。倒序会让 campaign id=1 那一瞬走 LLM
     路径，跟期望行为不一致。 -->

- [x] 6.1 备份 ECS PG `campaign` 表 — `ssh -i ~/codes/isales-4.pem root@121.89.85.150 'sudo -u postgres pg_dump -t campaign isales > /tmp/campaign-backup-$(date +%Y%m%d-%H%M%S).sql'` <!-- /tmp/campaign-backup-20260529-180732.sql 5.6K -->
- [x] 6.2 SCP 新 alembic migration 文件到 ECS（按 `[[feedback_ecs_deploy_scp]]` 规则）<!-- a908d5971908_add_campaign_greeting.py 落 ECS isales-common/alembic/versions/ -->
- [x] 6.3 在 ECS 上跑 `alembic upgrade head`，验证 `campaign` 表加了 `greeting TEXT NULL` 列：`\d campaign` 确认 <!-- b2c3d4e5f6a7 → a908d5971908; \d campaign 见 greeting text -->
- [x] 6.4 ECS PG SQL UPDATE：`UPDATE campaign SET greeting = '您好，我是智联招聘的小雨，请问您现在方便接电话吗？' WHERE id = 1;`（保持当前 hack 行为）<!-- UPDATE 1; SELECT length(greeting)=25 跟 hack 一致 -->
- [x] 6.5 SCP 新 `runtime_config.py`（hack 删除版本）到 ECS `/opt/isales/current/isales-engine/isales_engine/runtime_config.py` <!-- ECS 端 grep _FIXED_GREETINGS 已无；grep campaign.greeting 见单行 -->
- [x] 6.6 `ssh ... systemctl restart isales-engine` <!-- systemctl is-active = active -->
- [x] 6.7 ECS journalctl 验证 `isales_engine_started` + `credentials_loaded count=5` 无 import error <!-- 18:09:08 cloud_edge_grpc_server_started → credentials_loaded count=5 providers=[dashscope, volcengine] → isales_engine_started -->


## 7. 联合验收

- [ ] 7.1 mac dev DingRTC 真拨号（按 memory `project_macos_dev_path` 的一行启动命令；JWT + RTC env 用 `~/.isales/edge-dev.jwt` + `~/.isales/rtc.env`，详见 session 2026-05-29 流程）
- [ ] 7.2 拨通后听 greeting，应跟当前一致：「您好，我是智联招聘的小雨，请问您现在方便接电话吗？」
- [ ] 7.3 ECS engine log grep TTS first_byte，应见 `text_len=25` first_byte
- [ ] 7.4 ECS 端验证一次 isales-web 编辑流程：改 greeting 为略不同的文案（如加个"哈哈"在末尾），保存；下一通 dial 听到的 greeting 应是新文案，无需 engine 重启

## 8. Archive 准备

- [x] 8.1 跑 `openspec validate campaign-fixed-greeting --strict` 全绿 <!-- Change 'campaign-fixed-greeting' is valid -->
- [x] 8.2 isales-common 仓 commit + push（model 改动）<!-- 4ee81f0 main 含 model + schema + alembic migration -->
- [x] 8.3 isales-engine 仓 commit + push（hack 删除）<!-- 792606f dingrtc-migration-cloud（active dev branch, fast-forward）-->
- [x] 8.4 isales-web 仓 commit + push（表单字段）<!-- 5acb1a9 main 含 types + BasicTab + CampaignEdit normalize -->
- [x] 8.5 isales-api 仓（如改了）commit + push <!-- c8d8a3b main 含 CampaignNestedUpdate.greeting -->
- [x] 8.6 部署侧 alembic 仓 commit + push <!-- alembic migration 直接放 isales-common alembic/versions/，跟着 4ee81f0 一起 push 完成 -->

- [x] 8.7 meta-repo `~/codes/isales` commit 本 change 全 4 artifact + tasks.md 进度回写 <!-- 1f67481 main 含 tasks.md § 1-6 + § 8.1-8.6 进度回写 -->
- [x] 8.8 meta-repo push origin main <!-- fe4272d..1f67481 main -> main -->

- [ ] 8.9 跑 `/opsx:archive campaign-fixed-greeting`，合并 spec delta（data-model + web-admin-ui）到对应 `openspec/specs/<capability>/spec.md`，移动 change 目录到 `openspec/changes/archive/YYYY-MM-DD-campaign-fixed-greeting/`
- [ ] 8.10 archive 后 commit + push meta-repo
