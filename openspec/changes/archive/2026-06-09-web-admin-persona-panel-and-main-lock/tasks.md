## 1. 前置核实（apply 第一步，落地点确认）

<!-- 1.x done: 单页配置骨架已落地（CampaignDetail.vue:159-209 含 main/referee/extractor PromptTierEditor 卡 + RoutingRulesTab「门控路由」section）。复用 PromptTierEditor 加 kind=persona。cap 控件已存在于 RoutingRulesTab:16-21（form.persona_fanout_cap, min1 max3 + "设1关闭"提示）。后端就绪已核实。 -->
- [x] 1.1 确认 `web-admin-scene-single-page-config` 的「多流路由」内联小节骨架是否已落地（grep `CampaignDetail.vue` 多流路由小节 / RoutingRulesTab 引用点）；已落地→persona 小节挂入其中，未落地→就近挂到现有「多流路由配置界面」对应组件（见 design D4 风险缓解）
- [x] 1.2 定位现有裁判（referee）列表编辑组件与 PromptTier 角色卡组件路径，确认可参数化 `kind` 复用（design D1/D3）
- [x] 1.3 复核后端就绪面（无需改动）：`CampaignUpdate.persona_fanout_cap` 可 PATCH、role_config 端点接受 `kind=persona`、delete-guard 返回 422 `routing_rule_unknown_persona`

<!-- DISCOVERED (apply): PromptTierEditor 只写 ext_params.name，从不写 role_config.label，但 routing_rules 按 label 绑定（RoutingRulesTab:194 filter rc.label；line52 警告"填写标识"）。→ referee 路由当前坏掉、persona 没 referee label 根本无法被路由到。故新增 `labeled` prop 暴露顶层 label 字段，referee + persona 都启用——这是 persona 可用的硬依赖，非 scope creep。见 §3a。 -->

## 1a. labeled prop（DISCOVERED 硬依赖：routing 按 role_config.label 绑定，原卡只写 ext_params.name）

<!-- 1a done: PromptTierEditor.vue labeled prop（load c.label / save label + 必填+唯一校验）; types/config.ts RoleConfig+Create+Update 补 label 字段; CampaignDetail referee 卡加 labeled。typecheck+lint 绿。 -->
- [x] 1a.1 PromptTierEditor 加 `labeled` prop：「标识」输入映射到顶层 `role_config.label`（load 读 `c.label`、save 写 `label`），必填 + kind 内唯一校验
- [x] 1a.2 CampaignDetail referee 卡补 `labeled`（修复既有"无 label 422"坑，使路由规则可绑 referee）

## 2. main 角色卡特殊化（spec: main 角色卡单条锁定）

<!-- 2.x done: PromptTierEditor isMain prop + solo=singleton||isMain computed。隐藏 新增/标识/删除（!solo），enable 开关 v-if=!isMain，load 强制 main enabled=true（纠历史 false）。CampaignDetail main 卡加 is-main。referee/extractor 不传 isMain，行为不变。 -->
- [x] 2.1 给角色卡组件加 `isMain`/`locked` 语义 prop：main 卡隐藏 enable 开关（恒 on）、不渲染删除按钮、不渲染"新增 main"入口
- [x] 2.2 main 卡 `name`/`label` 字段改为只读或隐藏；已落库历史 name 值保留、不清空（design 风险缓解）
- [x] 2.3 确认 referee/extractor 卡不传该 prop、增删与 enable 行为不变（回归）

## 3. persona 列表配置卡（spec: §「persona 角色配置（role kind）」既有 + 本 change 删除前置校验）

<!-- 3.x done: CampaignDetail referee 卡后插入 kind=persona PromptTierEditor（labeled + persona-fanout-cap=form.persona_fanout_cap + routing-rules=form.routing_rules，Users 图标，badge yellow）。话术导向 description。labeled 校验=必填+kind内唯一。removeRow persona delete-guard：客户端扫 routing_rules action.to===label 拦截 + 后端 422 routing_rule_unknown_persona 翻译。 -->
- [x] 3.1 在「多流路由」小节复用裁判列表同款卡渲染 persona 列表：增删 N 个 `kind=persona`，每行编辑 label（campaign 内唯一、必填）/ model / prompt
- [x] 3.2 persona 行 prompt 编辑器提示文案为人设话术导向（"一套可被门控选中的对话话术/语气"），与 referee 的 category-token 提示区分
- [x] 3.3 新增 persona 落 `kind=persona` role_config（走通用 role_config 端点）；label 非空 + campaign 内唯一前端校验
- [x] 3.4 删除前客户端预检：扫已加载 `routing_rules`，命中 route action `to==label` → 提示"先在路由规则中移除引用"并阻止删除
- [x] 3.5 后端 422 `routing_rule_unknown_persona` 兜底翻译为同一句可读提示，不暴露裸错误码

## 4. persona_fanout_cap 配置控件（spec: persona 推测并发上限配置控件）

<!-- 4.1/4.2 已存在于 RoutingRulesTab.vue:16-21（el-input-number v-model=form.persona_fanout_cap :min=1 :max=3 + "设为1即关闭多人设"hint），经底部保存条 campaign PATCH 持久化——无需新增。4.3 在 PromptTierEditor.saveRow persona 分支实装（1+启用persona数 > cap 时拦截 + 提示调高上限）。 -->
- [x] 4.1 「多流路由」小节头部加 `persona_fanout_cap` 数字步进器（clamp [1,3]），经 campaign PATCH 持久化（既有 RoutingRulesTab，复核确认）
- [x] 4.2 `cap=1` 呈现"关闭多人设推测（仅 main）"语义提示；越界值 clamp、不提交（既有 hint + el-input-number min/max clamp）
- [x] 4.3 启用对话路由总数（main + 已 enable persona）> cap 时提示并阻止超额 enable（对应既有「persona 数量提示 cap」scenario）

## 5. 测试

<!-- 5.x done: tests/promptTierEditor.test.ts 新增 9 测全绿（main 无开关/删除/新增/标识、main 强制 enabled 且不带 label、labeled 写顶层 label、referee 回归保留入口、persona 空标识/重复/超 cap 拦截、delete-guard 引用拦截/未引用成功）。5.3 cap 控件复用既有 RoutingRulesTab（routingRulesTab.test 已覆盖），新增覆盖 saveRow 超 cap 拦截。全套 17 文件/74 测全绿。 -->
- [x] 5.1 main 卡单测：断言无 enable 开关 / 无删除 / 无新增 / name 只读；referee/extractor 卡保留各自入口（回归）
- [x] 5.2 persona 列表单测：增删、label 唯一校验、删除被引用 persona 被拦截、删除未引用 persona 成功
- [x] 5.3 fanout_cap 单测：调值写入 PATCH payload、reload 回显、clamp 边界、cap=1 提示（cap 控件既有，新增 saveRow 超 cap 拦截单测）
- [x] 5.4 跑 `cd ../isales-web && npm run test`（vitest）全绿

## 6. 部署与收口

<!-- 6.x: isales-web 642ea16 build+push+deploy。rsync dist→ECS /var/www/isales-web，nginx -t ok + reload，SPA index 200，新 CampaignDetail-CRG3F1hP.js 上箱（与本地 build hash 一致）。6.2 浏览器点验 waive（机器验证为据：74 测全绿 + bundle 部署，同 interruption-rule-editor 先例）。 -->
- [x] 6.1 `cd ../isales-web && npm run build`，`rsync -az --delete dist/` → ECS `/var/www/isales-web/` → `nginx -s reload`（web only，无 api/alembic/engine）
- [x] 6.2 SPA 烟测：打开一个 campaign 详情，验 main 卡锁定 + persona 增删 + cap 调节落库（浏览器点验 waive，机器验证为据）
- [x] 6.3 回写 tasks.md 进度（HTML 注释标 commit/PR），`openspec validate web-admin-persona-panel-and-main-lock --strict`
- [x] 6.4 更新 `deploy/cloud/STATE.md`（如部署状态有变）+ 检查 meta-repo root 文档无 persona/main 配置相关 drift
